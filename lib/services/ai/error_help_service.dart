import '../../core/errors/gitty_exception.dart';
import 'llm_client.dart';
import 'ollama_client.dart';

/// One message in the "Help with this error" conversation.
class HelpTurn {
  const HelpTurn({required this.fromUser, required this.text});

  final bool fromUser;
  final String text;
}

/// What the helper knows about the situation. Only error text, Git's output
/// and branch/count facts — never file contents.
class ErrorHelpContext {
  const ErrorHelpContext({
    required this.error,
    this.repoName,
    this.branch,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.changeCount = 0,
    this.conflictCount = 0,
    this.detached = false,
    this.githubAccount,
  });

  final GittyException error;

  /// GitHub username connected in Gitty's Settings, or null when none.
  final String? githubAccount;
  final String? repoName;
  final String? branch;
  final String? upstream;
  final int ahead;
  final int behind;
  final int changeCount;
  final int conflictCount;
  final bool detached;
}

/// Explains Git errors in plain language and answers follow-up questions,
/// using whichever AI engine is picked in Settings.
abstract interface class ErrorHelpService {
  /// e.g. "llama3.2 via Ollama" or "Claude".
  String get engineName;

  /// Runs on this computer — nothing leaves it.
  bool get isLocal;

  /// Why help can't be used right now (e.g. AI switched off), or null.
  String? get unavailableReason;

  /// Answers about [context]. With [question] it's a follow-up to
  /// [history]; otherwise the first explanation. [onText] receives the
  /// answer so far for engines that stream.
  Future<String> ask(
    ErrorHelpContext context, {
    List<HelpTurn> history = const [],
    String? question,
    void Function(String textSoFar)? onText,
  });
}

// --- Prompt ------------------------------------------------------------------

const _system = '''
You are the helper inside Gitty, a calm, friendly desktop Git app for people
who are new to Git. Something just went wrong. Explain it simply and help
them fix it safely.

Write plain text only — no markdown, no **bold**, no headings with #.
First answer uses this shape:
What happened: one or two short sentences, no jargon (or explain it).
How to fix it:
1. ...
2. ...

Gitty's real features (these are the ONLY ones that exist):
- Repository screen buttons: Fetch, Pull (then choose Pull, Pull + Rebase or
  Pull + Merge), Push (called Publish for a branch that isn't online yet),
  New branch, Switch branch.
- Changes list: stage / unstage files, Stage all, Revert changes (with Undo),
  and "Resolve conflicts" (side-by-side: keep yours, keep incoming, keep
  both or write your own; then Finish or Cancel the merge/rebase).
- "Put changes aside" shelf: parks uncommitted work (stash) and brings it
  back later. Gitty offers it by itself when a switch or pull is blocked.
- History (clock icon in the header): everything that happened, with Undo
  for commits, pulls, merges, rebases, switches and new branches.
- Pull request card (GitHub): Open a pull request, see checks and reviews.
- Commit box, with "Generate with AI" for the message.
- Header: Refresh, Open in terminal, Open in VS Code, Show in Finder/Explorer.
- Cards on the repository screen: .gitignore editor, Git identity (the name
  and email used for commits), adding a remote.
- Settings: GitHub (Connect GitHub / Disconnect — Gitty then uses that account
  whenever the computer's own saved sign-in fails), AI engine, background
  fetch.

Rules:
- Never mention a button, menu, screen or setting that isn't listed above.
- Trust "Known facts" and "Sign-in" over your own guesses.
- Only blame the internet connection if Git's output says it couldn't
  connect or resolve the host. An HTTP error code (401, 403, 404) means the
  server answered, so the connection is fine.
- Don't just say "try again": only suggest retrying after a concrete change,
  and name the change.
- Only give a terminal command when Gitty has no button for it. Put each
  command on its own line starting with "\$ ".
- Never suggest anything that can lose work (reset --hard, push --force,
  clean, checkout -- ., deleting branches) unless the user asks for it, and
  then warn clearly first.
- If you're not sure, say what to check instead of guessing.
- Keep it under 170 words. Follow-up answers can be shorter.''';

/// Facts about common errors, so the model doesn't have to guess.
List<String> _knownFacts(GittyException e) {
  final t = '${e.message}\n${e.hint ?? ''}\n${e.details ?? ''}'.toLowerCase();
  return [
    if (t.contains('error: 403') ||
        t.contains('write access to repository not granted') ||
        RegExp(r'permission to \S+ denied').hasMatch(t))
      'HTTP 403: the server was reached and recognised a sign-in, but that '
          'account or token is not allowed to do this on this repository. '
          'It is not an internet problem. Usual causes: (1) the computer has '
          'saved sign-in details for a different GitHub account, or a token '
          "that doesn't include this repository (on a Mac: Keychain Access, "
          'entry "github.com"); (2) the account is not the owner or a '
          'collaborator of the repository; (3) an organization restricts '
          'third-party app access. Fixes: connect the account that owns the '
          'repository in Settings → GitHub; if the wrong account is saved on '
          'the computer, remove that saved "github.com" sign-in; or ask the '
          'owner to add the account as a collaborator.',
    if (t.contains('error: 401') ||
        t.contains('authentication failed') ||
        t.contains('could not read username') ||
        t.contains('terminal prompts disabled'))
      'No valid sign-in for this remote. For github.com remotes, connecting '
          'GitHub in Settings fixes it.',
    if (t.contains('permission denied (publickey)'))
      'The remote URL uses SSH and no accepted SSH key is loaded. Adding the '
          'key to the Git host (or switching the remote to https and '
          'connecting GitHub in Settings) fixes it.',
    if (t.contains('non-fast-forward') ||
        t.contains('[rejected]') ||
        t.contains('fetch first'))
      "The remote has commits the user doesn't have. Fix: Pull (or Pull + "
          'Rebase / Pull + Merge), then Push.',
    if (t.contains('would be overwritten') || t.contains('your local changes'))
      'Uncommitted edits would be overwritten. Fix: commit them, or use '
          '"Put changes aside", then retry the action.',
    if (t.contains('clash') || t.contains('conflict'))
      'There are merge conflicts. Fix: "Resolve conflicts" in the changes '
          'list; if it went wrong, Cancel the merge/rebase there to go back.',
  ];
}

String _prompt(
  ErrorHelpContext c,
  List<HelpTurn> history,
  String? question,
) {
  final e = c.error;
  final details = e.details == null
      ? null
      : e.details!.length > 4000
      ? '${e.details!.substring(0, 4000)}\n…(cut)'
      : e.details;
  final state = <String>[
    if (c.repoName != null) 'repository folder "${c.repoName}"',
    if (c.detached)
      'not on a branch (detached HEAD)'
    else if (c.branch != null)
      c.upstream == null
          ? 'on branch "${c.branch}", which is not online yet'
          : 'on branch "${c.branch}", linked to "${c.upstream}"',
    if (c.ahead > 0) '${c.ahead} commit(s) not uploaded yet',
    if (c.behind > 0) '${c.behind} new commit(s) online not downloaded yet',
    c.changeCount == 0
        ? 'no uncommitted changes'
        : '${c.changeCount} uncommitted change(s)',
    if (c.conflictCount > 0) '${c.conflictCount} file(s) with conflicts',
  ];
  final facts = _knownFacts(e);
  return [
    'The error Gitty showed: ${e.message}',
    if (e.hint != null) "Gitty's hint: ${e.hint}",
    if (details != null) "Git's output:\n$details",
    if (state.isNotEmpty) 'Current state: ${state.join('; ')}.',
    c.githubAccount == null
        ? 'Sign-in: no GitHub account is connected in Gitty.'
        : 'Sign-in: GitHub account "${c.githubAccount}" is connected in Gitty.',
    if (facts.isNotEmpty) 'Known facts:\n- ${facts.join('\n- ')}',
    if (history.isNotEmpty)
      'Conversation so far:\n${history.map((t) => '${t.fromUser ? 'User' : 'Helper'}: ${t.text}').join('\n\n')}',
    question == null
        ? 'Explain what happened and how to fix it.'
        : 'The user asks: $question',
  ].join('\n\n');
}

/// Removes hidden reasoning and markdown the model added anyway.
String cleanHelpAnswer(String raw) {
  var s = raw.replaceAll(
    RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
    '',
  );
  // Still thinking (streaming): show nothing yet.
  if (RegExp('<think>', caseSensitive: false).hasMatch(s)) return '';
  s = s
      .replaceAll('**', '')
      .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^```[a-zA-Z]*\s*$', multiLine: true), '');
  return s.trim();
}

// --- Engines -----------------------------------------------------------------

class OllamaErrorHelpService implements ErrorHelpService {
  OllamaErrorHelpService({required OllamaClient client, required this.model})
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
  Future<String> ask(
    ErrorHelpContext context, {
    List<HelpTurn> history = const [],
    String? question,
    void Function(String textSoFar)? onText,
  }) async {
    if (!await _client.isReachable()) {
      throw const GittyException(
        "Ollama isn't running, so the local AI can't answer.",
        hint: 'Start Ollama, or pick another AI engine in Settings.',
      );
    }
    final raw = await _client.generate(
      model: model,
      system: _system,
      prompt: _prompt(context, history, question),
      think: false, // quick answers; retried without it if unsupported
      temperature: 0.2,
      onText: onText == null
          ? null
          : (text) {
              final visible = cleanHelpAnswer(text);
              if (visible.isNotEmpty) onText(visible);
            },
    );
    return _nonEmpty(cleanHelpAnswer(raw));
  }
}

class RemoteErrorHelpService implements ErrorHelpService {
  RemoteErrorHelpService({
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
  Future<String> ask(
    ErrorHelpContext context, {
    List<HelpTurn> history = const [],
    String? question,
    void Function(String textSoFar)? onText,
  }) async {
    final raw = await _client.complete(
      model: model,
      system: _system,
      prompt: _prompt(context, history, question),
    );
    return _nonEmpty(cleanHelpAnswer(raw));
  }
}

/// Used when AI is switched off in Settings.
class DisabledErrorHelpService implements ErrorHelpService {
  const DisabledErrorHelpService();

  @override
  String get engineName => 'AI';

  @override
  bool get isLocal => true;

  @override
  String? get unavailableReason =>
      'AI is switched off. Turn it on in Settings to get help here.';

  @override
  Future<String> ask(
    ErrorHelpContext context, {
    List<HelpTurn> history = const [],
    String? question,
    void Function(String textSoFar)? onText,
  }) async => throw GittyException(unavailableReason!);
}

String _nonEmpty(String answer) {
  if (answer.isEmpty) {
    throw const GittyException(
      'The AI returned an empty answer.',
      hint: 'Try again, or pick another model in Settings.',
    );
  }
  return answer;
}
