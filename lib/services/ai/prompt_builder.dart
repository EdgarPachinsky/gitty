import 'commit_message_service.dart';
import 'commit_style.dart';

/// Builds the system + user prompts sent to the AI engine (local or cloud).
///
/// The rules push models towards what a teammate wants to read in
/// `git log`: a short line about the *intent* of the change, with an
/// optional, tiny body — never a paragraph narrating the diff.
class CommitPromptBuilder {
  const CommitPromptBuilder();

  /// [quick] adds a nudge to answer right away — for local models, where
  /// every extra token is noticeable.
  String system(CommitStyle style, {bool quick = false}) {
    const base = """You write git commit messages that a teammate will read in `git log`.
Output ONLY the commit message text.

Rules:
- First line: what the change does for the project, in imperative mood ("Add", "Fix", "Configure"), at most 72 characters, no trailing period.
- Describe the intent, not the mechanics. Don't list file types or counts, and don't say things like "new XML files" or "all changes are additions".
- Never start with "This commit", "This change" or "This PR".
- Never output placeholders or labels such as <blank line>, Subject:, Body: — and no markdown (no **, #, or code fences).
- Most commits need no body. If one helps, leave one empty line after the first line, then at most 3 short "- " bullets about why or notable effects.
- Base everything strictly on the diff; never invent changes.

Example of what NOT to write:
chore: add .idea configuration files for standard IDE setup

This commit adds new XML and gitignore files under the .idea directory to configure IntelliJ IDEA project settings. All changes are additions with no modifications.

Write this instead:
chore: add IntelliJ project settings""";
    final rules = switch (style) {
      CommitStyle.conventional =>
        'Format the first line as "<type>(<optional scope>): <summary>". '
            'Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore. '
            'The summary is lowercase. Add a body only when the reason for the '
            'change isn\'t obvious from the first line.',
      CommitStyle.short =>
        'Output a single line only, at most 60 characters. No body.',
      CommitStyle.detailed =>
        'Write the first line, an empty line, then 2-4 "- " bullets with the '
            'notable changes. Keep each bullet under 80 characters.',
      CommitStyle.friendly =>
        'Write one or two warm, plain-English sentences (under 200 characters) '
            'that a non-expert teammate would understand. No bullets, no emojis.',
    };
    const hurry =
        '\n\nThis is a quick task: answer right away, without deliberating.';
    return '$base\n\nStyle: $rules${quick ? hurry : ''}';
  }

  /// [noThinkHint] appends Qwen3's "/no_think" switch.
  String user(CommitMessageRequest r, {bool noThinkHint = false}) {
    final b = StringBuffer();
    if (r.branch != null) b.writeln('Branch: ${r.branch}');
    if (r.summary != null && r.summary!.trim().isNotEmpty) {
      b
        ..writeln('The developer describes this work as:')
        ..writeln(r.summary!.trim())
        ..writeln();
    }
    b
      ..writeln('Files changed:')
      ..writeln(r.diffStat.isEmpty ? r.stagedFiles.join('\n') : r.diffStat)
      ..writeln()
      ..writeln('Diff:')
      ..writeln(r.diff)
      ..writeln()
      ..writeln('Now write the commit message.');
    if (noThinkHint) b.writeln('/no_think');
    return b.toString();
  }
}

/// Short prompts for small local models: few rules, concrete examples, and
/// a digest of the changes instead of the raw diff.
extension CompactCommitPrompts on CommitPromptBuilder {
  String systemCompact(CommitStyle style) {
    final (rule, examples) = switch (style) {
      CommitStyle.conventional => (
        'One line: "type(scope): summary". type is one of feat, fix, docs, '
            'style, refactor, perf, test, build, ci, chore. summary is '
            'lowercase, imperative, under 60 characters.',
        'feat(auth): add password reset by email\n'
            'fix(sync): stop crash when the remote is empty\n'
            'refactor(settings): move AI options into their own section',
      ),
      CommitStyle.short => (
        'One line, imperative ("Add", "Fix"), under 60 characters.',
        'Add password reset by email\n'
            'Fix crash when the remote is empty\n'
            'Move AI options into their own section',
      ),
      CommitStyle.detailed => (
        'First line: imperative summary under 60 characters. Then an empty '
            'line and 2-3 short "- " bullets saying what changed and why.',
        'Add password reset by email\n\n'
            '- Send a reset link that expires after an hour\n'
            '- Show a friendly page when the link is used twice',
      ),
      CommitStyle.friendly => (
        'One or two short, plain-English sentences a non-programmer would '
            'understand. No bullets.',
        'You can now reset your password by email if you forget it.',
      ),
    };
    return '''
You write git commit messages. Reply with the commit message only.
$rule
Say what the change does and why, not which files changed.
Never start with "This commit". No quotes, no markdown.

Good examples:
$examples''';
  }

  String userCompact(CommitMessageRequest r, String digest) {
    final b = StringBuffer();
    if (r.branch != null) b.writeln('Branch: ${r.branch}');
    if (r.summary != null && r.summary!.trim().isNotEmpty) {
      b
        ..writeln('What the developer says this is:')
        ..writeln(r.summary!.trim())
        ..writeln();
    }
    b
      ..writeln('Changes (file (+added −removed), then changed lines):')
      ..writeln(digest)
      ..writeln()
      ..write('Commit message:');
    return b.toString();
  }

  /// Why [message] isn't good enough, or null when it's fine.
  String? problemWith(String message, CommitStyle style, List<String> files) {
    final first = message.split('\n').first.trim();
    if (first.isEmpty) return 'it was empty';
    final lower = first.toLowerCase();
    if (lower.startsWith('this commit') ||
        lower.startsWith('this change') ||
        lower.startsWith('this pr')) {
      return 'it starts with "This commit"';
    }
    if (style != CommitStyle.friendly && first.length > 72) {
      return 'the first line is longer than 72 characters';
    }
    if (style == CommitStyle.conventional &&
        !RegExp(r'^[a-z]+(\([^)]*\))?!?: \S').hasMatch(first)) {
      return 'the first line doesn\'t follow "type(scope): summary"';
    }
    final named = files.where((f) {
      final name = f.split('/').last;
      return name.contains('.') && first.contains(name);
    }).length;
    if (named >= 2) return 'it lists file names instead of saying what changed';
    final summary = first.replaceFirst(RegExp(r'^[a-z]+(\([^)]*\))?!?:\s*'), '');
    if (RegExp(
      r'^(update|change|modify|edit)s?\s+(the\s+)?(files?|code|stuff)\b',
      caseSensitive: false,
    ).hasMatch(summary)) {
      return 'it is too vague';
    }
    return null;
  }
}

/// Cleans up typical LLM noise: reasoning blocks, code fences, wrapping quotes.
String cleanModelOutput(String raw) {
  var s = raw.replaceAll(
    RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
    '',
  );
  s = s.trim();
  final fence = RegExp(r'^```[a-zA-Z]*\s*\n?([\s\S]*?)\n?```$');
  final m = fence.firstMatch(s);
  if (m != null) s = m.group(1)!.trim();
  if (s.length > 1 &&
      ((s.startsWith('"') && s.endsWith('"')) ||
          (s.startsWith("'") && s.endsWith("'")))) {
    s = s.substring(1, s.length - 1).trim();
  }
  const prefixes = [
    'commit message:',
    'here is the commit message:',
    "here's the commit message:",
  ];
  for (final prefix in prefixes) {
    if (s.toLowerCase().startsWith(prefix)) {
      s = s.substring(prefix.length).trim();
    }
  }
  return s;
}

/// Turns raw model output into a tidy, human commit message.
///
/// Runs [cleanModelOutput], then removes things models like to add anyway:
/// "<blank line>" placeholders, "Subject:"/"Body:" labels, markdown, and
/// filler such as "This commit adds…" or "All changes are additions…". The
/// first line is kept short and the body is wrapped at 72 columns.
String polishCommitMessage(String raw, CommitStyle style) {
  var s = cleanModelOutput(raw).replaceAll('\r\n', '\n');

  final placeholder = RegExp(
    r'^\s*[<\[(]\s*(blank|empty)(\s+line)?\s*[>\])]\s*$',
    caseSensitive: false,
  );
  final label = RegExp(
    r'^\s*(\*\*|__)?(subject|summary|title|body|description|commit message)'
    r'(\*\*|__)?\s*:\s*(\*\*|__)?\s*',
    caseSensitive: false,
  );
  final lines = <String>[];
  for (var line in s.split('\n')) {
    if (placeholder.hasMatch(line)) {
      lines.add('');
      continue;
    }
    line = line
        .replaceFirst(label, '')
        .replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '')
        .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
        .replaceAll(RegExp(r'^\*\*\s*|\s*\*\*$'), '')
        .replaceFirstMapped(RegExp(r'^(\s*)[*•]\s+'), (m) => '${m[1]}- ')
        .trimRight();
    lines.add(line);
  }

  // Subject = first non-empty line.
  final first = lines.indexWhere((l) => l.trim().isNotEmpty);
  if (first < 0) return '';
  var subject = lines[first].trim();
  if (style != CommitStyle.friendly) {
    subject = subject.replaceFirst(RegExp(r'[.\s]+$'), '');
    subject = _clampLine(subject, style == CommitStyle.short ? 60 : 72);
  }
  if (style == CommitStyle.short) return subject;

  // Body: drop filler, then re-flow.
  final filler = RegExp(
    r'(all|these|the) changes are (additions|new files)[^.]*\.?|'
    r'with no (other )?(modifications|changes to existing files)[^.]*\.?|'
    r'no (existing )?files (were|are) (modified|changed)[^.]*\.?',
    caseSensitive: false,
  );
  final narrator = RegExp(
    r'^(\s*-\s*)?this (commit|change|pr|patch|update)\s+',
    caseSensitive: false,
  );
  final body = <String>[];
  for (final original in lines.skip(first + 1)) {
    var line = original.replaceAll(filler, '').trimRight();
    final m = narrator.firstMatch(line);
    if (m != null) {
      final rest = line.substring(m.end);
      line = '${m.group(1) ?? ''}${_capitalize(rest)}';
    }
    if (line.trim().isEmpty) {
      if (body.isNotEmpty && body.last.isNotEmpty) body.add('');
    } else {
      body.add(line.trim());
    }
  }
  while (body.isNotEmpty && body.last.isEmpty) {
    body.removeLast();
  }
  while (body.isNotEmpty && body.first.isEmpty) {
    body.removeAt(0);
  }

  // A long narrative paragraph in a "one-liner" style: keep one sentence.
  if (style == CommitStyle.conventional &&
      body.isNotEmpty &&
      !body.any((l) => l.startsWith('- '))) {
    final paragraph = body.join(' ').trim();
    if (paragraph.length > 160) {
      final end = paragraph.indexOf(RegExp(r'[.!?](\s|$)'));
      body
        ..clear()
        ..add(end > 0 ? paragraph.substring(0, end + 1) : paragraph);
    }
  }

  if (body.isEmpty) return subject;
  final wrapped = [for (final l in body) ..._wrap(l, 72)];
  return '$subject\n\n${wrapped.join('\n')}';
}

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Shortens [line] to at most [max] characters at a word boundary.
String _clampLine(String line, int max) {
  if (line.length <= max) return line;
  final cut = line.lastIndexOf(' ', max);
  return (cut > max ~/ 2 ? line.substring(0, cut) : line.substring(0, max))
      .replaceFirst(RegExp(r'[\s,;:.-]+$'), '');
}

/// Wraps [line] at [width]; bullet continuation lines are indented.
List<String> _wrap(String line, int width) {
  if (line.length <= width) return [line];
  final bullet = line.startsWith('- ');
  String lead(int index) => bullet ? (index == 0 ? '- ' : '  ') : '';
  final words = (bullet ? line.substring(2) : line)
      .split(' ')
      .where((w) => w.isNotEmpty);
  final out = <String>[];
  var current = '';
  for (final w in words) {
    final tooLong =
        lead(out.length).length + current.length + 1 + w.length > width;
    if (current.isNotEmpty && tooLong) {
      out.add(lead(out.length) + current);
      current = w;
    } else {
      current = current.isEmpty ? w : '$current $w';
    }
  }
  if (current.isNotEmpty) out.add(lead(out.length) + current);
  return out;
}
