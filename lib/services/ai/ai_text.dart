import '../../core/errors/gitty_exception.dart';
import 'diff_digest.dart';
import 'llm_client.dart';
import 'ollama_client.dart';

/// Plain "ask the AI for some text" access to the engine picked in
/// Settings — used for change summaries, names for changes put aside,
/// conflict explanations and pull request descriptions.
abstract interface class AiText {
  /// e.g. "llama3.2 via Ollama" or "Claude".
  String get engineName;

  /// Runs on this computer — nothing leaves it.
  bool get isLocal;

  /// Why it can't be used right now (e.g. AI switched off), or null.
  String? get unavailableReason;

  /// How much raw diff to fetch (see [prepareDiff]).
  int get maxInputChars;

  /// Shapes a raw diff for this engine: local models get a short digest
  /// they can follow, cloud models the diff itself.
  String prepareDiff(String diff);

  /// One answer. [onText] receives the text so far for engines that stream.
  Future<String> complete({
    required String system,
    required String prompt,
    void Function(String textSoFar)? onText,
  });
}

/// Removes hidden reasoning (`<think>…</think>`); returns '' while a model
/// is still thinking.
String stripThinking(String raw) {
  final s = raw.replaceAll(
    RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
    '',
  );
  if (RegExp('<think>', caseSensitive: false).hasMatch(s)) return '';
  return s.trim();
}

/// Removes one wrapping ``` fence (models like to add them around code).
String stripCodeFence(String s) {
  final m = RegExp(r'^```[^\n]*\n([\s\S]*?)\n?```\s*$').firstMatch(s.trim());
  return m == null ? s : m.group(1)!;
}

/// Plain one-liners and short notes: no markdown, no quotes around it.
String plainText(String raw) {
  var s = stripThinking(raw)
      .replaceAll('**', '')
      .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
      .trim();
  if (s.length > 1 &&
      ((s.startsWith('"') && s.endsWith('"')) ||
          (s.startsWith('“') && s.endsWith('”')))) {
    s = s.substring(1, s.length - 1).trim();
  }
  return s;
}

class OllamaAiText implements AiText {
  OllamaAiText({required OllamaClient client, required this.model})
    : _client = client;

  final OllamaClient _client;
  final String model;

  @override
  String get engineName => '$model via Ollama';

  @override
  bool get isLocal => true;

  @override
  String? get unavailableReason => null;

  @override
  int get maxInputChars => 30000;

  @override
  String prepareDiff(String diff) => digestDiff(diff, maxChars: 4500);

  @override
  Future<String> complete({
    required String system,
    required String prompt,
    void Function(String textSoFar)? onText,
  }) async {
    if (!await _client.isReachable()) {
      throw const GittyException(
        "Ollama isn't running, so the local AI can't answer.",
        hint: 'Start Ollama, or pick another AI engine in Settings.',
      );
    }
    // Never let the prompt overflow what Ollama reads: it would quietly
    // drop the beginning — the instructions.
    final room =
        (OllamaClient.contextTokens - 1200 - OllamaClient.estimateTokens(system)) *
        3;
    final fitted = prompt.length > room
        ? '${prompt.substring(0, room)}\n[…shortened]'
        : prompt;
    final raw = await _client.generate(
      model: model,
      system: system,
      prompt: fitted,
      think: false, // quick answers; retried without it if unsupported
      onText: onText == null
          ? null
          : (text) {
              final visible = stripThinking(text);
              if (visible.isNotEmpty) onText(visible);
            },
    );
    return _nonEmpty(stripThinking(raw));
  }
}

class RemoteAiText implements AiText {
  RemoteAiText({
    required LlmClient client,
    required this.model,
    required this.engineName,
  }) : _client = client;

  final LlmClient _client;
  final String model;

  @override
  final String engineName;

  @override
  bool get isLocal => false;

  @override
  String? get unavailableReason => model.trim().isEmpty
      ? 'Pick a model for $engineName in Settings first.'
      : null;

  @override
  int get maxInputChars => 16000;

  @override
  String prepareDiff(String diff) => diff;

  @override
  Future<String> complete({
    required String system,
    required String prompt,
    void Function(String textSoFar)? onText,
  }) async {
    final raw = await _client.complete(
      model: model,
      system: system,
      prompt: prompt,
    );
    return _nonEmpty(stripThinking(raw));
  }
}

/// Used when AI is switched off in Settings.
class DisabledAiText implements AiText {
  const DisabledAiText();

  @override
  String get engineName => 'AI';

  @override
  bool get isLocal => true;

  @override
  String? get unavailableReason =>
      'AI is switched off. Turn it on in Settings to use this.';

  @override
  int get maxInputChars => 0;

  @override
  String prepareDiff(String diff) => '';

  @override
  Future<String> complete({
    required String system,
    required String prompt,
    void Function(String textSoFar)? onText,
  }) async => throw GittyException(unavailableReason!);
}

String _nonEmpty(String answer) {
  if (answer.trim().isEmpty) {
    throw const GittyException(
      'The AI returned an empty answer.',
      hint: 'Try again, or pick another model in Settings.',
    );
  }
  return answer;
}
