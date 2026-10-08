import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/services/git/history.dart';

const _z = '0000000000000000000000000000000000000000';
const _a = 'a0248bb1eece96ef602fe3c3bd137ec807eb2b4a';
const _b = 'b1111111111111111111111111111111111111b1';

String line(String old, String now, int t, String msg) =>
    '$old $now Edgar <e@x.com> $t +0400\t$msg';

void main() {
  test('reflog becomes friendly activity, newest first', () {
    final events = parseActivity(
      currentBranch: 'feature/x',
      headLog: [
        line(_z, _a, 100, 'commit (initial): first'),
        line(_a, _a, 200, 'checkout: moving from main to feature/x'),
        line(_a, _b, 300, 'commit: add login'),
        line(_b, _a, 400, 'checkout: moving from feature/x to main'),
        line(_a, _b, 500, 'pull --ff-only: Fast-forward'),
        line(_b, _a, 600, "merge feature/x: Merge made by the 'ort' strategy."),
        line(_a, _a, 700, 'checkout: moving from main to feature/x'),
        line(_a, _b, 800, 'rebase (start): checkout main'),
        line(_b, _b, 801, 'rebase (finish): returning to refs/heads/feature/x'),
      ],
      branchLogs: {
        'feature/x': [line(_z, _a, 200, 'branch: Created from HEAD')],
        'dev2': [
          line(_z, _a, 250, 'branch: Created from main'),
          line(_a, _a, 260, 'Branch: renamed refs/heads/dev to refs/heads/dev2'),
        ],
      },
      remoteLogs: {
        'origin/feature/x': [line(_z, _b, 350, 'update by push')],
        'origin/main': [
          line(_a, _b, 450, 'update by push'),
          line(_a, _b, 490, 'fetch --all --prune: fast-forward'),
        ],
        'origin/new': [line(_z, _b, 491, 'fetch --all --prune: storing head')],
      },
    );
    final titles = events.map((e) => e.title).toList();
    expect(titles.first, 'Rebased feature/x onto main');
    expect(titles, contains('Merged feature/x into main'));
    expect(titles, contains('Pulled into main'));
    expect(titles, contains('Committed on feature/x'));
    expect(titles, contains('Made the first commit on main'));
    expect(
      titles,
      contains('Created branch feature/x from main and switched to it'),
    );
    expect(titles, contains('Created branch dev2 from main'));
    expect(titles, contains('Renamed branch dev to dev2'));
    expect(titles, contains('Published feature/x to origin'));
    expect(titles, contains('Pushed main to origin'));
    expect(titles, contains('Downloaded news from origin'));
    final download = events.firstWhere((e) => e.kind == ActivityKind.fetch);
    expect(download.detail, 'Main got new commits · new branch new');
    // The switch to feature/x at t=200 was merged into "Created … and switched".
    expect(
      events.where((e) => e.title == 'Switched from main to feature/x').length,
      1, // only the later one (t=700)
    );
  });

  test('commit log parsing', () {
    const out =
        '$_b\u001f$_a\u001fEdgar\u001fe@x.com\u001f1700000000\u001fHEAD -> main, origin/main, origin/HEAD, tag: v1\u001fAdd login\u001e\n'
        '$_a\u001f\u001fEdgar\u001fe@x.com\u001f1690000000\u001f\u001fFirst\u001e\n';
    final commits = parseCommitLog(out);
    expect(commits.length, 2);
    expect(commits.first.refs, ['main', 'origin/main', 'tag: v1']);
    expect(commits.first.subject, 'Add login');
    expect(commits.last.parents, isEmpty);
  });

  test('commit details parsing', () {
    final d = parseCommitDetails('Longer text\u001e\n\n3\t1\tlib/a.dart\n-\t-\timg.png\n');
    expect(d.body, 'Longer text');
    expect(d.files.length, 2);
    expect(d.files.first.added, 3);
    expect(d.files.last.added, isNull);
  });
}
