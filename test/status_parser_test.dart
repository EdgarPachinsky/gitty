import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/services/git/git_models.dart';
import 'package:gitty/services/git/git_service.dart';
import 'package:gitty/services/git/status_parser.dart';

void main() {
  group('parsePorcelainV2', () {
    test('parses branch headers, ahead/behind and entries', () {
      const out =
          '# branch.oid 1234567890abcdef\u0000'
          '# branch.head main\u0000'
          '# branch.upstream origin/main\u0000'
          '# branch.ab +2 -3\u0000'
          '1 M. N... 100644 100644 100644 aaa bbb lib/main.dart\u0000'
          '1 .M N... 100644 100644 100644 aaa bbb docs/read me.md\u0000'
          '2 R. N... 100644 100644 100644 aaa bbb R100 lib/new.dart\u0000lib/old.dart\u0000'
          'u UU N... 100644 100644 100644 100644 a b c conflict.txt\u0000'
          '? new file.txt\u0000';

      final s = parsePorcelainV2(out);

      expect(s.branch, 'main');
      expect(s.upstream, 'origin/main');
      expect(s.ahead, 2);
      expect(s.behind, 3);
      expect(s.syncState, SyncState.diverged);
      expect(s.headOid, '1234567890abcdef');
      expect(s.changes, hasLength(5));

      final staged = s.changes[0];
      expect(staged.path, 'lib/main.dart');
      expect(staged.staged, isTrue);
      expect(staged.unstaged, isFalse);

      final spaced = s.changes[1];
      expect(spaced.path, 'docs/read me.md');
      expect(spaced.unstaged, isTrue);

      final renamed = s.changes[2];
      expect(renamed.kind, FileChangeKind.renamed);
      expect(renamed.path, 'lib/new.dart');
      expect(renamed.originalPath, 'lib/old.dart');

      expect(s.changes[3].kind, FileChangeKind.conflicted);
      expect(s.changes[4].kind, FileChangeKind.untracked);
      expect(s.changes[4].path, 'new file.txt');
      expect(s.conflictCount, 1);
    });

    test('handles a fresh repo and detached HEAD', () {
      final fresh = parsePorcelainV2(
        '# branch.oid (initial)\u0000# branch.head main\u0000',
      );
      expect(fresh.hasCommits, isFalse);
      expect(fresh.syncState, SyncState.noUpstream);
      expect(fresh.isClean, isTrue);

      final detached = parsePorcelainV2(
        '# branch.oid abc\u0000# branch.head (detached)\u0000',
      );
      expect(detached.isDetached, isTrue);
      expect(detached.syncState, SyncState.detached);
    });
  });

  test('repoNameFromUrl', () {
    expect(
      GitService.repoNameFromUrl('https://github.com/octocat/Hello-World.git'),
      'Hello-World',
    );
    expect(GitService.repoNameFromUrl('git@github.com:owner/repo.git'), 'repo');
    expect(GitService.repoNameFromUrl('https://example.com/a/b/'), 'b');
  });
}
