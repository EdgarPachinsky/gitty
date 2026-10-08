/// Prompts for the smaller AI helpers: names for changes put aside, the
/// summary above the changes list, conflict explanations and pull request
/// descriptions. Each returns (system, prompt).
library;

/// How the changes are presented (a digest for local models, a diff for
/// cloud ones) — said once so small models know how to read it.
const _howToRead =
    'Changes are listed per file as "path (+added −removed)", optionally '
    'the functions/sections touched ("in: …"), then changed lines: "+" '
    'added, "-" removed.';

String _files(List<String> files, {int max = 60}) {
  if (files.isEmpty) return '(none)';
  final shown = files.take(max).map((f) => '- $f').join('\n');
  return files.length > max ? '$shown\n- …and ${files.length - max} more' : shown;
}

/// A short name for changes being put aside.
(String, String) shelfNamePrompt({
  required String diff,
  required List<String> files,
  String? branch,
}) => (
  '''
You name a set of unfinished code changes that a developer is putting aside
to come back to later. Reply with ONE short line (max 60 characters) that
says what the work is about, e.g. "Login form validation (half done)" or
"Try new colours on the settings page". Plain text: no quotes, no period at
the end, no "WIP", no file names unless it's a single file.
$_howToRead''',
  [
    if (branch != null) 'Branch: $branch',
    'Files:\n${_files(files)}',
    if (diff.trim().isNotEmpty) 'Changes:\n$diff',
  ].join('\n\n'),
);

/// The short summary shown above the changes list.
(String, String) changesSummaryPrompt({
  required String diff,
  required List<String> files,
  required List<String> newFiles,
  String? branch,
}) => (
  '''
Summarize a developer's uncommitted changes so they can see at a glance
what they're in the middle of. Write 1 to 4 short lines, each starting with
"• ", most important first. Describe what changed and why it seems to have
changed, in plain words — not a list of file names. Plain text only, no
headings, no markdown. If the changes are trivial, one line is enough.
$_howToRead

Example:
• Add a password reset flow: an email form and a reset link that expires
• Fix the settings page crashing when the config file is empty''',
  [
    if (branch != null) 'Branch: $branch',
    'Changed files:\n${_files(files)}',
    if (newFiles.isNotEmpty) 'New files (not in Git yet):\n${_files(newFiles)}',
    if (diff.trim().isNotEmpty) 'Diff:\n$diff',
  ].join('\n\n'),
);

/// Explains one clash in plain words.
(String, String) conflictExplainPrompt({
  required String path,
  required String oursName,
  required String theirsName,
  required String ours,
  required String theirs,
  String? base,
}) => (
  '''
You help someone new to Git resolve a merge conflict. Two versions of the
same part of a file clash. Explain in plain words, briefly:
1. What "$oursName" does here.
2. What "$theirsName" does here.
3. Which to keep — or whether both are needed and how to combine them.
Plain text, no markdown, under 120 words.''',
  [
    'File: $path',
    if (base != null) 'Original version (before either change):\n$base',
    '$oursName:\n$ours',
    '$theirsName:\n$theirs',
  ].join('\n\n'),
);

/// Asks for a combined version of one clash (code only).
(String, String) conflictMergePrompt({
  required String path,
  required String ours,
  required String theirs,
  String? base,
}) => (
  '''
Combine two conflicting versions of the same part of a file into one
version that keeps the intent of both. Reply with ONLY the combined text —
no explanation, no code fences, no conflict markers. Keep the original
indentation and style.''',
  [
    'File: $path',
    if (base != null) 'Original version:\n$base',
    'Version A:\n$ours',
    'Version B:\n$theirs',
  ].join('\n\n'),
);

/// A pull request description (GitHub markdown).
(String, String) pullRequestPrompt({
  required String branch,
  required String base,
  required String log,
  required String stat,
}) => (
  '''
Write a pull request description in GitHub markdown for the changes below.
Start with a 1–2 sentence summary. Then a "## Changes" section with short
bullet points (what and why, not file-by-file). Add "## How to test" only
if it's obvious from the changes. No title line, under 200 words.''',
  [
    'Branch "$branch" into "$base".',
    'Commits:\n$log',
    if (stat.isNotEmpty) 'Files changed:\n$stat',
  ].join('\n\n'),
);
