import '../../core/errors/gitty_exception.dart';
import 'commit_message_service.dart';
import 'diff_digest.dart';
import 'draft_commit_message_service.dart';
import 'ollama_client.dart';
import 'prompt_builder.dart';

/// Generates commit messages with a local Ollama model, falling back to the
/// offline [DraftCommitMessageService] when Ollama isn't available — so the
/// button always works and never blocks the user.
///
/// Tuned for speed on local hardware:
/// - reasoning ("thinking") is switched off, or set to its lowest level,
///   for models that support it (qwen3, deepseek-r1, gpt-oss, …);
/// - the answer is capped and streamed, so text appears as it's written;
/// - the model stays loaded between requests and is warmed up early;
/// - only a small, noise-free slice of the diff is sent.
class OllamaCommitMessageService implements CommitMessageService {
  OllamaCommitMessageService({
    required OllamaClient client,
    required this.model,
    CommitPromptBuilder prompts = const CommitPromptBuilder(),
    CommitMessageService fallback = const DraftCommitMessageService(),
  }) : _client = client,
       _prompts = prompts,
       _fallback = fallback;

  final OllamaClient _client;
  final String model;
  final CommitPromptBuilder _prompts;
  final CommitMessageService _fallback;

  /// `/api/show` results per "address|model", so we ask only once.
  static final _infoCache = <String, OllamaModelInfo?>{};

  /// The raw diff can be big: it's boiled down to a short digest (see
  /// [digestDiff]) before the model sees it.
  @override
  int get maxDiffChars => 30000;

  /// Room for the digest in the prompt (well inside
  /// [OllamaClient.contextTokens], with space left for the answer).
  static const _digestChars = 4500;

  Future<OllamaModelInfo?> _info() async {
    final key = '${_client.baseUrl}|$model';
    if (_infoCache.containsKey(key)) return _infoCache[key];
    final info = await _client.showModel(model);
    // Don't cache "unknown" — Ollama may simply not be running yet.
    if (info != null) _infoCache[key] = info;
    return info;
  }

  @override
  Future<void> warmUp() async {
    if (!await _client.isReachable()) return;
    await Future.wait([_info(), _client.warmUp(model)]);
  }

  @override
  Future<GeneratedCommitMessage> generate(
    CommitMessageRequest request, {
    void Function(String textSoFar)? onPartial,
  }) async {
    if (!await _client.isReachable()) {
      final draft = await _fallback.generate(request);
      return GeneratedCommitMessage(
        message: draft.message,
        engine: draft.engine,
        note:
            "Ollama isn't running, so here's a quick draft. Start Ollama for smarter messages.",
      );
    }

    try {
      final info = await _info();
      final think = info?.fastThinkSetting;
      final direct = info?.answersDirectly ?? false;
      final started = DateTime.now();
      // Small models follow a short digest and a short prompt far better
      // than a raw diff and a page of rules.
      final digest = digestDiff(request.diff, maxChars: _digestChars);
      final system = _prompts.systemCompact(request.style);
      var prompt = _prompts.userCompact(request, digest);
      if (_wantsNoThinkHint(info)) prompt = '$prompt\n/no_think';

      Future<String> ask(String prompt) => _client.generate(
        model: model,
        system: system,
        prompt: prompt,
        think: think,
        // A commit message is tiny. Cap it when no hidden reasoning has to
        // fit in the budget too.
        maxTokens: direct ? 320 : (info == null ? null : 2048),
        onText: onPartial == null
            ? null
            : (text) {
                // Some models inline their reasoning; don't show it.
                final lower = text.toLowerCase();
                if (lower.contains('<think>') && !lower.contains('</think>')) {
                  return;
                }
                final visible = cleanModelOutput(text);
                if (visible.isNotEmpty) onPartial(visible);
              },
      );

      var message = polishCommitMessage(await ask(prompt), request.style);
      // One more try when the answer breaks the rules — unless the model is
      // slow, so you're never kept waiting twice as long.
      final problem = _prompts.problemWith(
        message,
        request.style,
        request.stagedFiles,
      );
      if (problem != null &&
          DateTime.now().difference(started) < const Duration(seconds: 25)) {
        final retry = polishCommitMessage(
          await ask(
            '$prompt\n\nA first try was:\n$message\n'
            'That is not good enough because $problem. '
            'Write a better commit message.\n\nCommit message:',
          ),
          request.style,
        );
        if (retry.isNotEmpty &&
            _prompts.problemWith(retry, request.style, request.stagedFiles) ==
                null) {
          message = retry;
        }
      }
      if (message.isEmpty) {
        throw const GittyException('The model returned an empty message.');
      }
      final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
      return GeneratedCommitMessage(
        message: message,
        engine: '$model via Ollama',
        note: seconds > 20 && !direct
            ? 'That took ${seconds.round()}s because $model reasons before '
                  'answering. A small non-thinking model (e.g. llama3.2 or '
                  'qwen2.5-coder:3b) is much faster for commit messages.'
            : null,
      );
    } catch (error) {
      final friendly = toGittyException(error);
      final draft = await _fallback.generate(request);
      return GeneratedCommitMessage(
        message: draft.message,
        engine: draft.engine,
        note:
            '${friendly.message} ${friendly.hint ?? ''} Here\'s a quick draft instead.'
                .trim(),
      );
    }
  }

  /// Qwen3 also honours a "/no_think" switch in the prompt — useful on older
  /// Ollama versions that don't know the `think` option.
  bool _wantsNoThinkHint(OllamaModelInfo? info) =>
      model.toLowerCase().startsWith('qwen3') &&
      (info == null || info.fastThinkSetting != false);
}
