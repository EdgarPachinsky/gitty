import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/errors/gitty_exception.dart';
import 'llm_client.dart';

/// Anthropic Messages API client.
/// Docs: https://platform.claude.com/docs/en/api/messages
class ClaudeClient implements LlmClient {
  ClaudeClient({
    required Future<String?> Function() apiKey,
    this.baseUrl = 'https://api.anthropic.com',
    http.Client? client,
  }) : _apiKey = apiKey,
       _http = client ?? http.Client();

  /// Fast and inexpensive — plenty for commit messages.
  static const defaultModel = 'claude-haiku-4-5-20251001';

  /// Where people create API keys.
  static final keysPage = Uri.parse(
    'https://console.anthropic.com/settings/keys',
  );

  final Future<String?> Function() _apiKey;
  final String baseUrl;
  final http.Client _http;

  Future<Map<String, String>> _headers() async {
    final key = (await _apiKey())?.trim();
    if (key == null || key.isEmpty) {
      throw const GittyException(
        'Claude needs an API key first.',
        hint: 'Add one in Settings → Commit messages.',
      );
    }
    return {
      'x-api-key': key,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    };
  }

  @override
  Future<List<AiModel>> listModels() async {
    final res = await _http
        .get(Uri.parse('$baseUrl/v1/models?limit=100'), headers: await _headers())
        .timeout(const Duration(seconds: 15));
    _throwIfError(res, model: null);
    final json = _decode(res.body);
    final data = json['data'];
    if (data is! List) return const [];
    return [
      for (final m in data.whereType<Map<String, dynamic>>())
        if (m['id'] is String)
          AiModel(m['id'] as String, label: m['display_name'] as String?),
    ];
  }

  /// Models that turned down `output_config.effort` — don't send it again.
  static final _noEffort = <String>{};

  /// Low effort = little or no thinking = a fast answer. Haiku doesn't take
  /// the option (and is quick anyway).
  static bool _wantsLowEffort(String model) {
    final m = model.toLowerCase();
    if (m.contains('haiku') || _noEffort.contains(model)) return false;
    return m.contains('opus') ||
        m.contains('sonnet') ||
        m.contains('fable') ||
        m.contains('mythos');
  }

  @override
  Future<String> complete({
    required String model,
    required String system,
    required String prompt,
  }) async {
    Future<http.Response> send({required bool lowEffort}) async => _http
        .post(
          Uri.parse('$baseUrl/v1/messages'),
          headers: await _headers(),
          body: jsonEncode({
            'model': model,
            // Generous so models that think first still have room to answer.
            'max_tokens': 4096,
            if (lowEffort) 'output_config': {'effort': 'low'},
            'system': system,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
          }),
        )
        .timeout(const Duration(seconds: 90));

    final lowEffort = _wantsLowEffort(model);
    var res = await send(lowEffort: lowEffort);
    if (lowEffort &&
        res.statusCode == 400 &&
        RegExp('effort|output_config').hasMatch(res.body)) {
      _noEffort.add(model);
      res = await send(lowEffort: false);
    }
    _throwIfError(res, model: model);
    final json = _decode(res.body);
    final content = json['content'];
    final text = content is List
        ? content
              .whereType<Map<String, dynamic>>()
              .where((b) => b['type'] == 'text' && b['text'] is String)
              .map((b) => b['text'] as String)
              .join('\n')
        : '';
    if (text.trim().isEmpty) {
      throw GittyException(
        'Claude sent back an empty answer.',
        hint: 'Try again, or pick a different model in Settings.',
        details: res.body,
      );
    }
    return text;
  }

  static void _throwIfError(http.Response res, {required String? model}) {
    if (res.statusCode == 200) return;
    final message = _decode(res.body)['error'] is Map
        ? ((_decode(res.body)['error'] as Map)['message'] as String?)
        : null;
    GittyException e(String text, String hint) =>
        GittyException(text, hint: hint, details: message ?? res.body);
    throw switch (res.statusCode) {
      401 => e(
        'Claude didn’t accept that API key.',
        'Check the key in Settings → Commit messages.',
      ),
      403 => e(
        'This API key isn’t allowed to do that.',
        'Check the key’s permissions and workspace in the Claude Console.',
      ),
      404 => e(
        model == null
            ? 'Claude couldn’t find that page.'
            : 'The model “$model” isn’t available to your key.',
        'Pick another model in Settings.',
      ),
      429 => e(
        'Claude’s rate or spending limit was reached.',
        'Wait a moment, or check your limits in the Claude Console.',
      ),
      529 || 503 => e(
        'Claude is very busy right now.',
        'Try again in a minute.',
      ),
      _ => e('Claude returned an error.', 'See details for the full message.'),
    };
  }

  static Map<String, dynamic> _decode(String body) {
    try {
      final json = jsonDecode(body);
      return json is Map<String, dynamic> ? json : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}
