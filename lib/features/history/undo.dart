import '../../services/git/git_service.dart';
import '../../services/git/history.dart';

/// One way to undo a History event, explained before it runs.
class UndoPlan {
  const UndoPlan({
    required this.label,
    required this.title,
    required this.explanation,
    required this.run,
    this.danger = false,
    this.ifOnline,
    this.onlineHash,
  });

  /// Button text, e.g. "Undo" or "Switch back".
  final String label;

  /// Question at the top of the confirmation.
  final String title;

  /// What will happen, in plain words.
  final String explanation;

  /// Does it; returns the message to show.
  final Future<String> Function(GitService git, String repo) run;

  /// Affects something online — shown with a warning colour.
  final bool danger;

  /// When [onlineHash] is already online, this safer plan is used instead.
  final UndoPlan? ifOnline;
  final String? onlineHash;
}

/// What the repository looks like now.
class UndoContext {
  const UndoContext({
    required this.headOid,
    required this.currentBranch,
    required this.localBranches,
  });

  final String? headOid;
  final String? currentBranch;
  final Set<String> localBranches;
}

final _zeros = RegExp(r'^0+$');

/// How [e] can be undone right now, or null when it can't (safely).
UndoPlan? undoPlanFor(ActivityEvent e, UndoContext c) {
  final hasOld = e.oldHash != null && !_zeros.hasMatch(e.oldHash!);
  final onCurrent = e.branch != null && e.branch == c.currentBranch;
  // Nothing else has moved the branch since: going back loses nothing.
  final latest = onCurrent && e.hash != null && e.hash == c.headOid;
  final branch = e.branch ?? 'the branch';

  final revertPlan = e.hash == null
      ? null
      : UndoPlan(
          label: 'Undo with a new commit',
          title: 'Undo this commit safely?',
          explanation:
              'Gitty adds a new commit that reverses exactly what this one '
              'changed. History isn’t rewritten, so it’s the safe way to undo '
              'work that’s already shared. If it clashes with later changes, '
              'you’ll get to pick what to keep.',
          run: (git, repo) async {
            await git.revertCommit(repo, e.hash!);
            return 'Added a commit that undoes it. Push to share the fix.';
          },
        );

  switch (e.kind) {
    case ActivityKind.commit ||
        ActivityKind.amend ||
        ActivityKind.cherryPick ||
        ActivityKind.revert:
      if (latest && hasOld) {
        return UndoPlan(
          label: 'Undo',
          title: e.kind == ActivityKind.amend
              ? 'Undo this change to the last commit?'
              : 'Undo this commit?',
          explanation:
              'The commit is taken back, but none of your work is lost: its '
              'changes stay in your files, ready to commit again. Gitty keeps '
              'a safety copy too.',
          run: (git, repo) async {
            await git.moveBranchTo(repo, e.oldHash!, keepChangesStaged: true);
            return 'Undone — the changes are back in your files, ready to commit.';
          },
          ifOnline: revertPlan == null
              ? null
              : UndoPlan(
                  label: revertPlan.label,
                  title: 'This commit is already online',
                  explanation:
                      'Others may already have it, so taking it back could '
                      'cause trouble for them. ${revertPlan.explanation}',
                  run: revertPlan.run,
                ),
          onlineHash: e.hash,
        );
      }
      // An older commit on this branch: only the safe way.
      if (onCurrent && e.kind == ActivityKind.commit) return revertPlan;
      return null;

    case ActivityKind.pull ||
        ActivityKind.merge ||
        ActivityKind.rebase ||
        ActivityKind.reset:
      if (!latest || !hasOld) return null;
      return UndoPlan(
        label: 'Go back',
        title: 'Go back to before this?',
        explanation:
            '“$branch” goes back to exactly where it was before: '
            '“${e.title}” is undone. Your uncommitted edits are kept (Git '
            'stops if they’d clash). Gitty keeps a safety copy, and the undo '
            'shows up here too, so it can be undone as well.',
        run: (git, repo) async {
          await git.moveBranchTo(repo, e.oldHash!, keepChangesStaged: false);
          return 'Went back to before “${e.title}”.';
        },
      );

    case ActivityKind.switchBranch:
      final from = e.fromBranch;
      if (from == null || from == c.currentBranch) return null;
      if (c.localBranches.contains(from)) {
        return UndoPlan(
          label: 'Switch back',
          title: 'Switch back to “$from”?',
          explanation:
              'Your files change to “$from”’s version. Uncommitted edits come '
              'along; if they’d clash, Git stops and nothing changes.',
          run: (git, repo) async {
            await git.switchBranch(repo, from);
            return 'Switched back to “$from”.';
          },
        );
      }
      if (!hasOld) return null;
      return UndoPlan(
        label: 'Bring back branch',
        title: 'Bring back “$from”?',
        explanation:
            '“$from” doesn’t exist anymore. Gitty can recreate it at the last '
            'commit it had when you switched away from it.',
        run: (git, repo) async {
          await git.restoreBranch(repo, from, e.oldHash!);
          return 'Brought back “$from”.';
        },
      );

    case ActivityKind.createBranch:
      final name = e.branch;
      if (name == null ||
          !c.localBranches.contains(name) ||
          name == c.currentBranch) {
        return null;
      }
      return UndoPlan(
        label: 'Delete branch',
        title: 'Delete “$name”?',
        explanation:
            'The branch is removed from this computer. Gitty only does this '
            'when its commits are safe somewhere else, so no work is lost.',
        run: (git, repo) async {
          await git.deleteBranch(repo, name);
          return 'Deleted “$name”.';
        },
      );

    case ActivityKind.renameBranch:
      final now = e.branch;
      final before = e.renamedFrom;
      if (now == null ||
          before == null ||
          !c.localBranches.contains(now) ||
          c.localBranches.contains(before)) {
        return null;
      }
      return UndoPlan(
        label: 'Rename back',
        title: 'Rename “$now” back to “$before”?',
        explanation: 'Only the name changes — nothing else.',
        run: (git, repo) async {
          await git.renameBranch(repo, now, before);
          return 'Renamed back to “$before”.';
        },
      );

    case ActivityKind.publish:
      final published = e.branch;
      final remote = e.remote;
      if (published == null || remote == null) return null;
      return UndoPlan(
        label: 'Take offline',
        title: 'Remove “$published” from $remote?',
        danger: true,
        explanation:
            'The online copy of “$published” is deleted; your copy on this computer '
            'stays. Anyone who already downloaded it keeps theirs, and an open '
            'pull request for it will close.',
        run: (git, repo) async {
          await git.deleteRemoteBranch(repo, remote, published);
          return '“$published” is no longer on $remote.';
        },
      );

    default:
      return null;
  }
}
