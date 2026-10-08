import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/services/ai/commit_style.dart';
import 'package:gitty/services/ai/prompt_builder.dart';

void main() {
  test('removes placeholders, narration and filler', () {
    const raw =
        'chore: add .idea configuration files for standard IDE setup\n\n'
        '<blank line>\n'
        'This commit adds new XML and gitignore files under the .idea '
        'directory. All changes are additions with no modifications.';
    final out = polishCommitMessage(raw, CommitStyle.conventional);
    expect(out, isNot(contains('<blank line>')));
    expect(out, isNot(contains('This commit')));
    expect(out, isNot(contains('All changes are additions')));
    expect(out.split('\n').first,
        'chore: add .idea configuration files for standard IDE setup');
    expect(out, contains('\n\nAdds new XML'));
    expect(out.split('\n').every((l) => l.length <= 72), isTrue);
  });

  test('strips labels and markdown, turns * bullets into dashes', () {
    const raw =
        '**Subject:** Fix login crash.\n\n**Body:**\n* Handle null token';
    expect(
      polishCommitMessage(raw, CommitStyle.detailed),
      'Fix login crash\n\n- Handle null token',
    );
  });

  test('short style keeps one clamped line', () {
    final out = polishCommitMessage(
      'Add login screen with remember-me checkbox and a very long tail that '
      'goes past sixty characters\n\nbody here',
      CommitStyle.short,
    );
    expect(out.contains('\n'), isFalse);
    expect(out.length, lessThanOrEqualTo(60));
  });

  test('prompt carries the anti-narration rules', () {
    final system = const CommitPromptBuilder().system(CommitStyle.conventional);
    expect(system, contains('Never start with "This commit"'));
    expect(system, contains('<blank line>'));
  });
}
