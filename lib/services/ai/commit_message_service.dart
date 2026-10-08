import 'commit_style.dart';

/// Input for commit message generation.
class CommitMessageRequest {
  const CommitMessageRequest({
    required this.diff,
    required this.diffStat,
    required this.stagedFiles,
    required this.style,
    this.branch,
    this.summary,
  });

  /// Staged diff (already truncated to a sensible size).
  final String diff;

  /// `git diff --cached --stat` output.
  final String diffStat;
  final List<String> stagedFiles;
  final CommitStyle style;
  final String? branch;

  /// The note above the changes list ("what I'm working on"), when there is
  /// one — the best hint about *why*, which models can't see in a diff.
  final String? summary;
}

class GeneratedCommitMessage {
  const GeneratedCommitMessage({
    required this.message,
    required this.engine,
    this.note,
  });

  final String message;

  /// Human-readable source, e.g. "llama3.2 via Ollama" or "Quick draft".
  final String engine;

  /// Optional gentle note shown under the message (e.g. why we fell back).
  final String? note;
}

/// Anything that can write a commit message. Implementations: Ollama (local
/// LLM) and a rule-based offline draft. Swap or add engines freely.
abstract interface class CommitMessageService {
  /// Writes a message. [onPartial] receives the text so far while a model
  /// is still writing (engines that can't stream simply never call it).
  Future<GeneratedCommitMessage> generate(
    CommitMessageRequest request, {
    void Function(String textSoFar)? onPartial,
  });

  /// How much of the staged diff is worth sending. Local models read slowly,
  /// so they get a smaller, noise-free slice; 0 means "no diff needed".
  int get maxDiffChars;

  /// Gets the engine ready (e.g. loads a local model into memory) so the
  /// first "Generate" is fast. Best-effort; never throws.
  Future<void> warmUp();
}
