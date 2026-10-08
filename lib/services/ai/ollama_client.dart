import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/errors/gitty_exception.dart';

/// Minimal client for a locally running Ollama server.
/// API reference: https://github.com/ollama/ollama/blob/main/docs/api.md
class OllamaClient {
  OllamaClient({required this.baseUrl, http.Client? client})
    : _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  Uri _uri(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  /// True if the server answers at all.
  Future<bool> isReachable() async {
    try {
      final res = await _http
          .get(_uri('/api/version'))
          .timeout(const Duration(seconds: 2));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Names of locally installed models (e.g. `llama3.2:latest`).
  Future<List<String>> listModels() async {
    final res = await _http
        .get(_uri('/api/tags'))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      throw GittyException("Couldn't list Ollama models.", details: res.body);
    }
    final json = jsonDecode(res.body);
    if (json is! Map<String, dynamic>) return const [];
    final models = json['models'];
    if (models is! List) return const [];
    return [
      for (final m in models.whereType<Map<String, dynamic>>())
        if (m['name'] is String) m['name'] as String,
    ]..sort();
  }

  /// Starts downloading [model] (`ollama pull`). Listen to
  /// [OllamaPull.progress]; call [OllamaPull.cancel] to pause or stop.
  /// Ollama keeps partial downloads, so pulling again resumes.
  OllamaPull pull(String model) {
    // A dedicated connection, so cancelling can't affect other requests.
    final client = http.Client();
    final controller = StreamController<OllamaPullProgress>();
    var cancelled = false;

    Future<void> run() async {
      try {
        final request = http.Request('POST', _uri('/api/pull'))
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode({'model': model, 'name': model, 'stream': true});
        final response = await client.send(request);
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          throw _pullError(model, body);
        }
        // Each layer (blob) reports its own completed/total bytes.
        final layers = <String, (int, int)>{};
        final lines = response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        await for (final line in lines) {
          if (line.trim().isEmpty) continue;
          final Object? json;
          try {
            json = jsonDecode(line);
          } catch (_) {
            continue;
          }
          if (json is! Map<String, dynamic>) continue;
          if (json['error'] is String) {
            throw _pullError(model, json['error'] as String);
          }
          final status = json['status'] as String? ?? '';
          final digest = json['digest'] as String?;
          final total = (json['total'] as num?)?.toInt();
          if (digest != null && total != null && total > 0) {
            final done = (json['completed'] as num?)?.toInt() ?? 0;
            layers[digest] = (done, total);
          }
          var completed = 0;
          var size = 0;
          for (final (layerDone, layerTotal) in layers.values) {
            completed += layerDone;
            size += layerTotal;
          }
          controller.add(
            OllamaPullProgress(
              status: status,
              completed: completed,
              total: size,
              done: status == 'success',
            ),
          );
        }
      } catch (e) {
        if (!cancelled) controller.addError(e);
      } finally {
        client.close();
        await controller.close();
      }
    }

    unawaited(run());
    return OllamaPull._(controller.stream, () {
      cancelled = true;
      client.close(); // Aborts the transfer.
    });
  }

  static GittyException _pullError(String model, String raw) {
    final text = raw.toLowerCase();
    if (text.contains('file does not exist') ||
        text.contains('manifest unknown') ||
        text.contains('not found')) {
      return GittyException(
        'Ollama doesn’t have a model called “$model”.',
        hint: 'Check the name on ollama.com/library (e.g. llama3.2 or gemma3:4b).',
        details: raw,
      );
    }
    if (text.contains('no space left')) {
      return GittyException(
        'There isn’t enough disk space for “$model”.',
        hint: 'Free some space (or delete a model you don’t use) and try again.',
        details: raw,
      );
    }
    return GittyException(
      'Ollama couldn’t download “$model”.',
      hint: 'Check your internet connection and try again.',
      details: raw,
    );
  }

  /// Removes an installed model and frees its disk space.
  Future<void> deleteModel(String model) async {
    final request = http.Request('DELETE', _uri('/api/delete'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'model': model, 'name': model});
    final response = await _http
        .send(request)
        .timeout(const Duration(seconds: 30));
    final body = await response.stream.bytesToString();
    if (response.statusCode == 200 || response.statusCode == 404) return;
    throw GittyException('Ollama couldn’t delete “$model”.', details: body);
  }

  /// How long Ollama keeps the model in memory after a request. Loading a
  /// model is often the slowest part, so keep it around while you work.
  static const keepAlive = '30m';

  /// Thinking support of [model], from `/api/show`. Null if unknown (older
  /// Ollama, or the call failed).
  Future<OllamaModelInfo?> showModel(String model) async {
    try {
      final res = await _http
          .post(
            _uri('/api/show'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'model': model}),
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body);
      if (json is! Map<String, dynamic>) return null;
      final capabilities = json['capabilities'];
      final thinking = json['thinking'];
      return OllamaModelInfo(
        canThink: capabilities is List && capabilities.contains('thinking'),
        thinkValues: thinking is Map && thinking['values'] is List
            ? List<Object>.from(
                (thinking['values'] as List).whereType<Object>(),
              )
            : const [],
      );
    } catch (_) {
      return null;
    }
  }

  /// How much text (in tokens) Gitty asks Ollama to read at once. Ollama's
  /// own default is small (often 2–4k); a longer prompt is silently cut
  /// from the *start* — which is where the instructions are. Always the same
  /// value, so the model isn't reloaded between requests.
  static const contextTokens = 8192;

  /// Rough size of [text] in tokens (code averages ~3.2 characters each).
  static int estimateTokens(String text) => (text.length / 3.2).ceil();

  /// Loads [model] into memory without generating anything.
  Future<void> warmUp(String model) async {
    try {
      await _http
          .post(
            _uri('/api/generate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'keep_alive': keepAlive,
              'options': {'num_ctx': contextTokens},
            }),
          )
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      // Best-effort.
    }
  }

  /// Streams one completion and returns the full answer text.
  ///
  /// - [think]: `false` to switch reasoning off, a level such as `"low"`,
  ///   or null for the model default (see [OllamaModelInfo.fastThinkSetting]).
  /// - [maxTokens]: hard cap on generated tokens (`num_predict`).
  /// - [onText]: called with the answer so far as it streams in.
  /// - [idleTimeout]: gives up if Ollama goes quiet for this long.
  Future<String> generate({
    required String model,
    required String prompt,
    String? system,
    double temperature = 0.2,
    Object? think,
    int? maxTokens,
    void Function(String textSoFar)? onText,
    Duration idleTimeout = const Duration(seconds: 60),
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final request = http.Request('POST', _uri('/api/generate'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': model,
        'prompt': prompt,
        if (system != null) 'system': system,
        'stream': true,
        if (think != null) 'think': think,
        'keep_alive': keepAlive,
        'options': {
          'temperature': temperature,
          'num_ctx': contextTokens,
          if (maxTokens != null) 'num_predict': maxTokens,
        },
      });

    final response = await _http.send(request).timeout(idleTimeout);

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      // Older Ollama / models that reject the `think` option: retry without.
      if (think != null &&
          response.statusCode == 400 &&
          body.toLowerCase().contains('think')) {
        return generate(
          model: model,
          prompt: prompt,
          system: system,
          temperature: temperature,
          maxTokens: maxTokens,
          onText: onText,
          idleTimeout: idleTimeout,
          timeout: timeout,
        );
      }
      if (response.statusCode == 404) {
        throw GittyException(
          'The model "$model" isn\'t installed in Ollama.',
          hint: 'Run: ollama pull $model — or pick another model in Settings.',
          details: body,
        );
      }
      throw GittyException('Ollama returned an error.', details: body);
    }

    final deadline = DateTime.now().add(timeout);
    final answer = StringBuffer();
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(idleTimeout);
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final Object? json;
      try {
        json = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (json is! Map<String, dynamic>) continue;
      if (json['error'] is String) {
        throw GittyException(
          'Ollama stopped with an error.',
          details: json['error'] as String,
        );
      }
      final chunk = json['response'];
      if (chunk is String && chunk.isNotEmpty) {
        answer.write(chunk);
        onText?.call(answer.toString());
      }
      if (json['done'] == true) break;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Ollama took longer than ${timeout.inSeconds}s');
      }
    }
    return answer.toString();
  }
}

/// What Gitty knows about a local model's reasoning ("thinking") mode.
class OllamaModelInfo {
  const OllamaModelInfo({required this.canThink, this.thinkValues = const []});

  /// The model reasons before answering (qwen3, deepseek-r1, gpt-oss, …).
  final bool canThink;

  /// Allowed values for the `think` option, e.g. `[low, medium, high]`.
  final List<Object> thinkValues;

  /// The quickest `think` setting this model allows: off when possible,
  /// otherwise the lowest level; null means "don't send the option".
  Object? get fastThinkSetting {
    if (thinkValues.isNotEmpty) {
      if (thinkValues.contains(false)) return false;
      for (final level in ['none', 'off', 'minimal', 'low']) {
        if (thinkValues.contains(level)) return level;
      }
      return null;
    }
    return canThink ? false : null;
  }

  /// True when the model will answer straight away (no hidden reasoning).
  bool get answersDirectly => !canThink || fastThinkSetting == false;
}

/// A running `ollama pull`.
class OllamaPull {
  OllamaPull._(this.progress, this._cancel);

  /// Progress updates; completes when done, errors on failure. Stays silent
  /// (just completes) after [cancel].
  final Stream<OllamaPullProgress> progress;
  final void Function() _cancel;

  void cancel() => _cancel();
}

class OllamaPullProgress {
  const OllamaPullProgress({
    required this.status,
    required this.completed,
    required this.total,
    required this.done,
  });

  /// Ollama's phase, e.g. "pulling manifest", "verifying sha256 digest".
  final String status;
  final int completed;
  final int total;
  final bool done;

  double? get fraction => total > 0 ? (completed / total).clamp(0.0, 1.0) : null;
}
