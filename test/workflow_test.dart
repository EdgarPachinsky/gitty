import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/features/history/undo.dart';
import 'package:gitty/services/git/history.dart';
import 'package:gitty/services/git/workflow_models.dart';

void main() {
  group('conflict markers', () {
    test('splits a clash and rebuilds the file', () {
      const text =
          'a\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> dev\nb\n';
      final segments = parseConflictMarkers(text);
      expect(segments.length, 3);
      final clash = segments[1] as ClashSegment;
      expect(clash.ours, 'mine\n');
      expect(clash.theirs, 'theirs\n');
      expect(clash.oursLabel, 'HEAD');
      expect(clash.theirsLabel, 'dev');
      final rebuilt = segments
          .map((s) => switch (s) {
                PlainSegment(:final text) => text,
                ClashSegment(:final ours) => ours,
              })
          .join();
      expect(rebuilt, 'a\nmine\nb\n');
    });

    test('diff3 base section and empty sides', () {
      const text =
          '<<<<<<< ours\n||||||| base\nold\n=======\nnew\n>>>>>>> theirs\n';
      final clash = parseConflictMarkers(text).single as ClashSegment;
      expect(clash.ours, '');
      expect(clash.base, 'old\n');
      expect(clash.theirs, 'new\n');
    });

    test('broken markers are left as text', () {
      const text = 'x\n<<<<<<< HEAD\nno end\n';
      final segments = parseConflictMarkers(text);
      expect(segments.whereType<ClashSegment>(), isEmpty);
    });
  });

  test('unmerged files know which side deleted them', () {
    final files = parseUnmerged(
      '100644 aaa 1\tboth.txt\n100644 bbb 2\tboth.txt\n100644 ccc 3\tboth.txt\n'
      '100644 ddd 1\tgone.txt\n100644 eee 3\tgone.txt\n',
    );
    expect(files.length, 2);
    expect(files.first.path, 'both.txt');
    expect(files.first.isDeleteConflict, isFalse);
    expect(files.last.inOurs, isFalse);
    expect(files.last.inTheirs, isTrue);
  });

  test('stash list names', () {
    final list = parseStashList(
      'h1\u001f1700000000\u001fOn main: Login form (half done)\n'
      'h2\u001f1690000000\u001fWIP on dev: abc123 Some commit\n',
    );
    expect(list.first.message, 'Login form (half done)');
    expect(list.first.branch, 'main');
    expect(list.first.named, isTrue);
    expect(list.last.named, isFalse);
    expect(list.last.index, 1);
  });

  group('undo', () {
    const head = 'b1111111111111111111111111111111111111b1';
    const old = 'a0248bb1eece96ef602fe3c3bd137ec807eb2b4a';
    final ctx = const UndoContext(
      headOid: head,
      currentBranch: 'main',
      localBranches: {'main', 'feature/x'},
    );

    test('latest commit can be taken back (keeping changes)', () {
      final plan = undoPlanFor(
        ActivityEvent(
          kind: ActivityKind.commit,
          time: DateTime(2026),
          title: 'Committed on main',
          hash: head,
          oldHash: old,
          branch: 'main',
        ),
        ctx,
      );
      expect(plan?.label, 'Undo');
      expect(plan?.ifOnline?.label, 'Undo with a new commit');
    });

    test('a pull that is no longer the latest step is not undone', () {
      final plan = undoPlanFor(
        ActivityEvent(
          kind: ActivityKind.pull,
          time: DateTime(2026),
          title: 'Pulled into main',
          hash: old, // something happened after
          oldHash: '0123456789012345678901234567890123456789',
          branch: 'main',
        ),
        ctx,
      );
      expect(plan, isNull);
    });

    test('switching can be reversed; the current branch can’t be deleted', () {
      expect(
        undoPlanFor(
          ActivityEvent(
            kind: ActivityKind.switchBranch,
            time: DateTime(2026),
            title: 'Switched from feature/x to main',
            branch: 'main',
            fromBranch: 'feature/x',
          ),
          ctx,
        )?.label,
        'Switch back',
      );
      expect(
        undoPlanFor(
          ActivityEvent(
            kind: ActivityKind.createBranch,
            time: DateTime(2026),
            title: 'Created branch main',
            branch: 'main',
          ),
          ctx,
        ),
        isNull,
      );
    });
  });
}
