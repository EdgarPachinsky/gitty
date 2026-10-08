import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/features/settings/ollama_models_controller.dart';
import 'package:gitty/services/ai/ollama_client.dart';

void main() {
  test('model names match with or without :latest', () {
    expect(sameOllamaModel('llama3.2:latest', 'llama3.2'), isTrue);
    expect(sameOllamaModel('llama3.2', 'llama3.2:latest'), isTrue);
    expect(sameOllamaModel('qwen2.5-coder:3b', 'qwen2.5-coder:3b'), isTrue);
    expect(sameOllamaModel('qwen2.5-coder:7b', 'qwen2.5-coder:3b'), isFalse);
  });

  test('progress maths', () {
    const d = ModelDownload(
      model: 'llama3.2',
      phase: ModelDownloadPhase.downloading,
      completed: 500000000,
      total: 2000000000,
      bytesPerSecond: 10000000,
    );
    expect(d.fraction, 0.25);
    expect(d.timeLeft, const Duration(seconds: 150));
    expect(d.isActive, isTrue);
    expect(
      d.copyWith(phase: ModelDownloadPhase.paused).isActive,
      isFalse,
    );
  });

  test('friendly sizes and times', () {
    expect(formatBytes(2019000000), '2.0 GB');
    expect(formatBytes(341000000), '341 MB');
    expect(formatTimeLeft(const Duration(seconds: 5)), 'a few seconds left');
    expect(formatTimeLeft(const Duration(minutes: 3)), 'about 3 min left');
  });

  test('pull progress fraction', () {
    const p = OllamaPullProgress(
      status: 'pulling abc',
      completed: 50,
      total: 200,
      done: false,
    );
    expect(p.fraction, 0.25);
  });
}
