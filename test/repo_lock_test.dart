import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/core/errors/gitty_exception.dart';
import 'package:gitty/services/git/git_cli.dart';
import 'package:gitty/services/git/git_models.dart';

void main() {
  test('a lock-file error becomes RepoLockedException with the path', () {
    const stderr =
        "fatal: Unable to create '/Users/me/projects/css-fusion/.git/index.lock': "
        'File exists.\n\nAnother git process seems to be running in this repository';
    final e = mapGitError(
      ['add', '--all'],
      const GitCommandResult(128, '', stderr),
    );
    expect(e, isA<RepoLockedException>());
    expect(
      (e as RepoLockedException).lockPath,
      '/Users/me/projects/css-fusion/.git/index.lock',
    );
  });

  test('only unused, not-brand-new locks count as leftovers', () {
    final old = DateTime.now().subtract(const Duration(minutes: 3));
    expect(
      GitLockInfo(path: 'x', exists: true, inUse: false, modified: old).isLeftover,
      isTrue,
    );
    expect(
      GitLockInfo(path: 'x', exists: true, inUse: true, modified: old).isLeftover,
      isFalse,
    );
    expect(
      GitLockInfo(path: 'x', exists: true, inUse: null, modified: old).isLeftover,
      isFalse,
    );
    expect(
      GitLockInfo(
        path: 'x',
        exists: true,
        inUse: false,
        modified: DateTime.now(),
      ).isLeftover,
      isFalse,
    );
  });
}
