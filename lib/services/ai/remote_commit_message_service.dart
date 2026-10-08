import '../../core/errors/gitty_exception.dart';
import 'commit_message_service.dart';
import 'draft_commit_message_service.dart';
import 'llm_client.dart';
import 'prompt_builder.dart';

/// Writes commit messages with a cloud (or any HTTP) model such as Claude.
///
/// If the engine fails — no key, offline, rate limited — it hands over to
/// [fallback] (local Ollama when enabled, otherwise the offline draft), and
/// says so in the note. "Generate with AI" never dead-ends.
class RemoteCommitMessageService implements CommitMessageService {
  RemoteCommitMessageService({
    required LlmClient client,
    required this.model,
    required this.engineName,
    CommitPromptBuilder prompts = const CommitPromptBuilder(),
    CommitMessageService fallback = const DraftCommitMessageService(),
  }) : _client = client,
       _prompts = prompts,
       _fallback = fallback;

  final LlmClient _client;
  final String model;

  /// e.g. "Claude" — shown as "Written by <model> via Claude".
  final String engineName;
  final CommitPromptBuilder _prompts;
  final CommitMessageService _fallback;

  /// Cloud models read fast, so they get more context than local ones.
  @override
  int get maxDiffChars => 16000;

  @override
  Future<void> warmUp() async {}

  @override
  Future<GeneratedCommitMessage> generate(
    CommitMessageRequest request, {
    void Function(String textSoFar)? onPartial,
  }) async {
    try {
      final raw = await _client.complete(
        model: model,
        system: _prompts.system(request.style),
        prompt: _prompts.user(request),
      );
      final message = polishCommitMessage(raw, request.style);
      if (message.isEmpty) {
        throw GittyException('$engineName returned an empty message.');
      }
      return GeneratedCommitMessage(
        message: message,
        engine: '$model via $engineName',
      );
    } catch (error) {
      final friendly = toGittyException(error);
      final backup = await _fallback.generate(request, onPartial: onPartial);
      return GeneratedCommitMessage(
        message: backup.message,
        engine: backup.engine,
        note: [
          '$engineName: ${friendly.message}',
          if (friendly.hint != null) friendly.hint!,
          'This one came from ${backup.engine} instead.',
          if (backup.note != null) backup.note!,
        ].join(' '),
      );
    }
  }
}
