import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/features/sync/live_sync.dart';
import 'package:gitty/services/git/git_models.dart';

void main() {
  test('branch tree children are most-recent first', () {
    final tree = BranchTree(
      root: 'main',
      nodes: [
        const BranchNode(name: 'main', isRoot: true),
        BranchNode(name: 'old', parent: 'main', lastCommitAt: DateTime(2026)),
        BranchNode(name: 'new', parent: 'main', lastCommitAt: DateTime(2026, 9)),
        BranchNode(name: 'fix', parent: 'new', lastCommitAt: DateTime(2026, 9)),
      ],
    );
    expect(tree.childrenOf('main').map((n) => n.name), ['new', 'old']);
    expect(tree.childrenOf('new').single.name, 'fix');
    expect(tree.node('fix')?.parent, 'new');
  });

  RemoteNotice notice(RemoteNoticeKind kind, List<String> authors, int n) =>
      RemoteNotice(
        id: 1,
        repoPath: '/work/gitty',
        kind: kind,
        at: DateTime(2026),
        yourBranch: 'feature',
        update: RemoteUpdate(
          remoteRef: 'origin/main',
          branch: 'main',
          newCommits: n,
          authors: authors,
        ),
      );

  test('friendly notice sentences', () {
    final parent = notice(RemoteNoticeKind.parentBranch, ['Ana'], 3);
    expect(parent.isImportant, isTrue);
    expect(parent.message, contains('Ana pushed 3 new changes to “main”'));
    expect(parent.message, contains('“feature” grew from'));

    final mine = notice(RemoteNoticeKind.yourBranch, ['Ana', 'Bob'], 1);
    expect(mine.who, 'Ana and Bob');
    expect(mine.message, contains('1 new change'));

    expect(notice(RemoteNoticeKind.other, ['A', 'B', 'C'], 2).who, 'A and 2 others');
    expect(notice(RemoteNoticeKind.newBranch, const [], 0).isImportant, isFalse);
  });
}
