import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/core/errors/gitty_exception.dart';
import 'package:gitty/services/auth/git_provider.dart';
import 'package:gitty/services/git/git_cli.dart';
import 'package:gitty/services/git/git_models.dart';
import 'package:gitty/services/git/git_service.dart';

void main() {
  test('missing author identity becomes its own error type', () {
    const stderr =
        'Author identity unknown\n\n*** Please tell me who you are.\n\n'
        "fatal: unable to auto-detect email address (got '_me@mac.(none)')";
    final e = mapGitError(
      ['commit', '-m', 'x'],
      const GitCommandResult(128, '', stderr),
    );
    expect(e, isA<MissingIdentityException>());
    expect(e.hint, isNot(contains('--global')));
  });

  test('identity validation', () {
    expect(GitService.validateIdentity('Ed', 'ed@example.com'), isNull);
    expect(GitService.validateIdentity('', 'ed@example.com'), isNotNull);
    expect(GitService.validateIdentity('Ed', 'not-an-email'), isNotNull);
    expect(GitService.validateIdentity('Ed <x>', 'ed@example.com'), isNotNull);
  });

  test('GitHub no-reply email', () {
    const withId = ProviderAccount(
      kind: GitProviderKind.github,
      username: 'octocat',
      id: 583231,
    );
    expect(withId.noreplyEmail, '583231+octocat@users.noreply.github.com');
    const withoutId = ProviderAccount(
      kind: GitProviderKind.github,
      username: 'octocat',
    );
    expect(withoutId.noreplyEmail, 'octocat@users.noreply.github.com');
  });

  test('identity completeness and scope', () {
    const local = GitIdentity(
      name: 'Ed',
      email: 'ed@example.com',
      nameScope: 'local',
      emailScope: 'local',
    );
    expect(local.isComplete, isTrue);
    expect(local.isLocal, isTrue);
    expect(const GitIdentity(name: 'Ed').isComplete, isFalse);
  });
}
