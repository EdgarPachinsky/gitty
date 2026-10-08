import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/gitty_exception.dart';
import '../../services/ai/ollama_client.dart';
import '../../services/service_providers.dart';

/// Installed Ollama models (empty if Ollama isn't reachable).
final ollamaModelsProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  final client = ref.watch(ollamaClientProvider);
  if (!await client.isReachable()) return const [];
  return client.listModels();
});

/// True when an installed model name refers to [model]
/// (`llama3.2` ↔ `llama3.2:latest`).
bool sameOllamaModel(String installed, String model) =>
    installed == model ||
    installed == '$model:latest' ||
    '$installed:latest' == model;

enum ModelDownloadPhase { starting, downloading, finishing, paused, failed }

/// One model being installed.
class ModelDownload {
  const ModelDownload({
    required this.model,
    required this.phase,
    this.completed = 0,
    this.total = 0,
    this.bytesPerSecond,
    this.error,
  });

  final String model;
  final ModelDownloadPhase phase;
  final int completed;
  final int total;
  final double? bytesPerSecond;
  final GittyException? error;

  double? get fraction =>
      total > 0 ? (completed / total).clamp(0.0, 1.0) : null;

  bool get isActive =>
      phase == ModelDownloadPhase.starting ||
      phase == ModelDownloadPhase.downloading ||
      phase == ModelDownloadPhase.finishing;

  Duration? get timeLeft {
    final speed = bytesPerSecond;
    if (speed == null || speed <= 0 || total <= 0) return null;
    return Duration(seconds: ((total - completed) / speed).round());
  }

  ModelDownload copyWith({
    ModelDownloadPhase? phase,
    int? completed,
    int? total,
    double? bytesPerSecond,
    GittyException? error,
  }) => ModelDownload(
    model: model,
    phase: phase ?? this.phase,
    completed: completed ?? this.completed,
    total: total ?? this.total,
    bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
    error: error,
  );
}

/// Installs and deletes local models, one download per model at a time.
/// App-wide, so downloads keep going while you look at other screens.
class ModelDownloadsController extends Notifier<Map<String, ModelDownload>> {
  final _pulls = <String, OllamaPull>{};
  final _subscriptions = <String, StreamSubscription<OllamaPullProgress>>{};
  final _lastSample = <String, (DateTime, int)>{};

  @override
  Map<String, ModelDownload> build() {
    ref.onDispose(() {
      for (final pull in _pulls.values) {
        pull.cancel();
      }
    });
    return const {};
  }

  OllamaClient get _client => ref.read(ollamaClientProvider);

  void _put(ModelDownload d) => state = {...state, d.model: d};

  void _remove(String model) =>
      state = {...state}..remove(model);

  /// Starts (or resumes) installing [model].
  Future<void> install(String model) async {
    final name = model.trim();
    if (name.isEmpty) return;
    if (state[name]?.isActive ?? false) return;

    final previous = state[name];
    _put(
      ModelDownload(
        model: name,
        phase: ModelDownloadPhase.starting,
        completed: previous?.completed ?? 0,
        total: previous?.total ?? 0,
      ),
    );

    if (!await _client.isReachable()) {
      _put(
        state[name]!.copyWith(
          phase: ModelDownloadPhase.failed,
          error: const GittyException(
            'Ollama isn’t running.',
            hint: 'Start Ollama (or install it from ollama.com), then try again.',
          ),
        ),
      );
      return;
    }

    final pull = _client.pull(name);
    _pulls[name] = pull;
    _lastSample.remove(name);
    _subscriptions[name] = pull.progress.listen(
      (p) => _onProgress(name, p),
      onError: (Object e) {
        _cleanup(name);
        final current = state[name];
        if (current == null) return;
        _put(
          current.copyWith(
            phase: ModelDownloadPhase.failed,
            error: toGittyException(e),
          ),
        );
      },
      onDone: () {
        final finished = _pulls.containsKey(name);
        _cleanup(name);
        // Completed normally (not paused/stopped): it's installed.
        if (finished && (state[name]?.isActive ?? false)) {
          _remove(name);
          ref.invalidate(ollamaModelsProvider);
        }
      },
    );
  }

  void _onProgress(String model, OllamaPullProgress p) {
    final current = state[model];
    if (current == null || !current.isActive) return;

    // Smoothed download speed from the last sample.
    double? speed = current.bytesPerSecond;
    final now = DateTime.now();
    final last = _lastSample[model];
    if (last == null) {
      _lastSample[model] = (now, p.completed);
    } else {
      final seconds = now.difference(last.$1).inMilliseconds / 1000;
      if (seconds >= 1) {
        final instant = (p.completed - last.$2) / seconds;
        if (instant >= 0) {
          speed = speed == null ? instant : speed * 0.7 + instant * 0.3;
        }
        _lastSample[model] = (now, p.completed);
      }
    }

    final finishing =
        p.status.startsWith('verifying') ||
        p.status.startsWith('writing') ||
        p.status == 'success';
    _put(
      current.copyWith(
        phase: finishing
            ? ModelDownloadPhase.finishing
            : p.total > 0
            ? ModelDownloadPhase.downloading
            : ModelDownloadPhase.starting,
        completed: p.total > 0 ? p.completed : current.completed,
        total: p.total > 0 ? p.total : current.total,
        bytesPerSecond: speed,
      ),
    );
  }

  /// Pauses — the partial download stays on disk; [install] resumes it.
  void pause(String model) {
    _pulls[model]?.cancel();
    _cleanup(model);
    final current = state[model];
    if (current != null) {
      _put(current.copyWith(phase: ModelDownloadPhase.paused));
    }
  }

  /// Stops and forgets the download. (Ollama clears unfinished files the
  /// next time it starts.)
  void stop(String model) {
    _pulls[model]?.cancel();
    _cleanup(model);
    _remove(model);
  }

  /// Deletes an installed model and frees its disk space.
  Future<void> delete(String model) async {
    await _client.deleteModel(model);
    ref.invalidate(ollamaModelsProvider);
  }

  void _cleanup(String model) {
    _pulls.remove(model);
    unawaited(_subscriptions.remove(model)?.cancel());
    _lastSample.remove(model);
  }
}

final modelDownloadsProvider =
    NotifierProvider<ModelDownloadsController, Map<String, ModelDownload>>(
      ModelDownloadsController.new,
    );

/// "1.2 GB", "340 MB".
String formatBytes(int bytes) {
  if (bytes >= 1000 * 1000 * 1000) {
    return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1000 * 1000) return '${(bytes / 1e6).round()} MB';
  if (bytes >= 1000) return '${(bytes / 1e3).round()} KB';
  return '$bytes B';
}

/// "about 3 min left", "a few seconds left".
String formatTimeLeft(Duration d) {
  if (d.inSeconds < 10) return 'a few seconds left';
  if (d.inMinutes < 1) return '${d.inSeconds}s left';
  if (d.inHours < 1) return 'about ${d.inMinutes} min left';
  return 'about ${d.inHours} h ${d.inMinutes % 60} min left';
}
