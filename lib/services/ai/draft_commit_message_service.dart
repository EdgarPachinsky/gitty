import 'package:path/path.dart' as p;

import 'commit_message_service.dart';
import 'commit_style.dart';

/// Rule-based, fully offline commit message drafts.
///
/// This is the stub engine: it's used when AI is turned off or Ollama isn't
/// running, so "Generate" always produces something sensible to edit.
class DraftCommitMessageService implements CommitMessageService {
  const DraftCommitMessageService();

  @override
  int get maxDiffChars => 0; // Works from file names only.

  @override
  Future<void> warmUp() async {}

  @override
  Future<GeneratedCommitMessage> generate(
    CommitMessageRequest r, {
    void Function(String textSoFar)? onPartial,
  }) async {
    final files = r.stagedFiles;
    final type = _guessType(files);
    final subject = _subject(files);

    final message = switch (r.style) {
      CommitStyle.conventional =>
        '$type${_scope(files)}: ${subject.toLowerCase()}',
      CommitStyle.short => _capitalize(subject),
      CommitStyle.detailed =>
        '${_capitalize(subject)}\n\n${files.take(8).map((f) => '- Update $f').join('\n')}'
            '${files.length > 8 ? '\n- …and ${files.length - 8} more' : ''}',
      CommitStyle.friendly =>
        'Worked on ${files.length == 1 ? p.basename(files.first) : '${files.length} files'} — a small, focused update.',
    };

    return GeneratedCommitMessage(message: message, engine: 'Quick draft');
  }

  String _subject(List<String> files) {
    if (files.isEmpty) return 'Update project';
    if (files.length == 1) return 'Update ${p.basename(files.first)}';
    final dirs = files.map((f) => p.dirname(f)).toSet();
    if (dirs.length == 1 && dirs.first != '.') {
      return 'Update ${files.length} files in ${dirs.first}';
    }
    return 'Update ${files.length} files';
  }

  String _guessType(List<String> files) {
    bool all(bool Function(String) test) =>
        files.isNotEmpty && files.every(test);
    if (all((f) => f.endsWith('.md') || f.startsWith('docs/'))) return 'docs';
    if (all((f) => f.contains('test'))) return 'test';
    if (all((f) => f.startsWith('.github/'))) return 'ci';
    if (all(
      (f) => const {
        'pubspec.yaml',
        'pubspec.lock',
        'package.json',
        'package-lock.json',
      }.contains(p.basename(f)),
    )) {
      return 'build';
    }
    return 'chore';
  }

  String _scope(List<String> files) {
    if (files.isEmpty) return '';
    final tops = files.map((f) => p.split(f).first).toSet();
    if (tops.length == 1 && files.first.contains('/')) return '(${tops.first})';
    return '';
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
