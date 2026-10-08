import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/gitty_exception.dart';
import '../../core/utils/provider_cache.dart';
import '../../core/utils/task_limiter.dart';
import '../../core/utils/time_ago.dart';
import '../../services/git/git_models.dart';
import '../../services/git/git_service.dart';
import '../../services/git/workflow_models.dart';
import '../../services/service_providers.dart';
import '../../services/storage/analytics_repository.dart';
import '../dashboard/tracked_repos_controller.dart';
import '../sync/live_sync.dart';

enum GitAction {
  fetch,
  pull,
  push,
  stage,
  unstage,
  commit,
  createBranch,
  switchBranch,
  init,
  addRemote,
  gitignore,
  identity,
  merge,
  link,
  revert,
  shelf,
  undo,
  resolve,
  renameBranch,
}

/// Result of a user-triggered action, ready to show in a snackbar.
class ActionOutcome {
  const ActionOutcome.success(this.message, {this.data}) : error = null;
  ActionOutcome.failure(GittyException this.error)
    : message = error.message,
      data = null;

  final String message;
  final GittyException? error;

  /// Extra result, e.g. the backup id of a revert (for "Undo").
  final Object? data;

  bool get ok => error == null;
}

/// Runs Git actions for one repository, one at a time.
///
/// State is the action currently running (null when idle) so buttons can show
/// spinners and disable themselves.
class RepoActionsController extends Notifier<GitAction?> {
  RepoActionsController(this.repoPath);

  final String repoPath;

  @override
  GitAction? build() => null;

  GitService get _git => ref.read(gitServiceProvider);

  Future<ActionOutcome> fetch() =>
      _run(GitAction.fetch, AnalyticsEventType.fetch, () async {
        await _git.fetch(repoPath);
        return 'Fetched the latest from the remote.';
      });

  Future<ActionOutcome> pull(PullStrategy strategy) =>
      _run(GitAction.pull, AnalyticsEventType.pull, () async {
        await _git.pull(repoPath, strategy);
        return switch (strategy) {
          PullStrategy.fastForwardOnly => "Pulled — you're up to date.",
          PullStrategy.rebase => 'Pulled and rebased your work on top.',
          PullStrategy.merge => 'Pulled and merged the remote changes.',
        };
      }, meta: {'strategy': strategy.name});

  Future<ActionOutcome> push() =>
      _run(GitAction.push, AnalyticsEventType.push, () async {
        await _git.push(repoPath);
        return 'Pushed! Your commits are on the remote.';
      });

  Future<ActionOutcome> stageAll() => _run(GitAction.stage, null, () async {
    await _git.stageAll(repoPath);
    return 'Staged everything.';
  });

  Future<ActionOutcome> stage(List<String> paths) =>
      _run(GitAction.stage, null, () async {
        await _git.stage(repoPath, paths);
        return 'Staged ${plural(paths.length, 'file')}.';
      });

  Future<ActionOutcome> unstage(List<String> paths) =>
      _run(GitAction.unstage, null, () async {
        await _git.unstage(repoPath, paths);
        return 'Unstaged ${plural(paths.length, 'file')}.';
      });

  Future<ActionOutcome> unstageAll() => _run(GitAction.unstage, null, () async {
    await _git.unstageAll(repoPath);
    return 'Unstaged everything.';
  });

  Future<ActionOutcome> commit(
    String message, {
    required bool leavesDirtyTree,
  }) => _run(
    GitAction.commit,
    AnalyticsEventType.commit,
    () async {
      final hash = await _git.commit(repoPath, message);
      return 'Committed $hash — nice work!';
    },
    meta: {'dirtyAfter': leavesDirtyTree},
  );

  /// Creates [name] from [from] (null = where you are now). Switching to it
  /// and pushing it are independent choices.
  Future<ActionOutcome> createBranch(
    String name, {
    String? from,
    required bool switchToIt,
    bool push = false,
  }) => _run(GitAction.createBranch, AnalyticsEventType.branchCreated, () async {
    await _git.createBranch(
      repoPath,
      name,
      switchToIt: switchToIt,
      from: from,
    );
    final created = from == null
        ? 'Created "$name"'
        : 'Created "$name" from "$from"';
    final switched = switchToIt ? ' and switched to it' : '';
    if (!push) return '$created$switched.';
    try {
      final remote = await _git.publishBranch(repoPath, name);
      return '$created$switched, and pushed it to $remote.';
    } catch (e) {
      // The branch exists either way — say so, then why the push failed.
      final error = toGittyException(e);
      throw GittyException(
        '$created$switched, but couldn’t push it: ${error.message}',
        hint: error.hint,
        details: error.details,
      );
    }
  });

  Future<ActionOutcome> switchBranch(String name) =>
      _run(GitAction.switchBranch, AnalyticsEventType.branchSwitched, () async {
        await _git.switchBranch(repoPath, name);
        return 'Switched to "$name".';
      });

  Future<ActionOutcome> initRepository() =>
      _run(GitAction.init, null, () async {
        await _git.init(repoPath);
        return 'Git is set up! Now let’s give it a home online.';
      });

  /// Connects `origin` (or [name]) to [url] and links branches if possible.
  Future<ActionOutcome> connectRemote(String url, {String name = 'origin'}) =>
      _run(GitAction.addRemote, null, () async {
        final c = await _git.connectRemote(repoPath, url, name: name);
        if (c.fetchError != null) {
          return 'Added $name. Gitty couldn’t reach it yet (${c.fetchError!.message}) — '
              'it will try again when you fetch or push.';
        }
        if (c.adoptedBranch != null) {
          return 'Connected to $name and brought in “${c.adoptedBranch}” from the remote.';
        }
        if (c.adoptError != null) {
          throw c.adoptError!;
        }
        if (c.linkedBranch != null) {
          return 'Connected to $name and linked “${c.linkedBranch}” to $name/${c.linkedBranch}.';
        }
        if (c.remoteIsEmpty) {
          return 'Connected to $name. Commit, then Publish to send your work there.';
        }
        return 'Connected to $name.';
      });

  /// Writes (or extends) .gitignore. [hidden] is how many changes the new
  /// rules take out of the changes list, for a friendlier message.
  Future<ActionOutcome> addGitignore(
    String content, {
    required bool append,
    int hidden = 0,
  }) => _run(GitAction.gitignore, null, () async {
    await _git.writeGitignore(repoPath, content, append: append);
    final tidy = hidden > 0
        ? ' ${plural(hidden, 'item')} no longer clutter your changes.'
        : '';
    return append
        ? 'Updated .gitignore.$tidy Commit it so everyone gets the same rules.'
        : 'Added .gitignore.$tidy Commit it so everyone gets the same rules.';
  });

  /// Sets who commits in this repository (local config only).
  Future<ActionOutcome> setIdentity(String name, String email) =>
      _run(GitAction.identity, null, () async {
        await _git.setLocalIdentity(repoPath, name, email);
        return 'Saved — commits here will be by ${name.trim()}.';
      });

  /// Brings the latest of the branch this one grew from (e.g. `origin/main`)
  /// into the current branch with a merge — nothing is rewritten.
  Future<ActionOutcome> bringInParent(String parentRef, {String? label}) =>
      _run(GitAction.merge, AnalyticsEventType.pull, () async {
        await _git.mergeInto(repoPath, parentRef);
        return 'Brought the latest “${label ?? parentRef}” into your branch.';
      }, meta: {'strategy': 'parent-merge'});

  /// Brings [branch]'s changes into the current branch (its online version
  /// when [online]).
  Future<ActionOutcome> pullFromBranch(
    String branch, {
    required bool online,
    required bool rebase,
  }) => _run(GitAction.merge, AnalyticsEventType.pull, () async {
    final n = await _git.pullFromBranch(
      repoPath,
      branch,
      online: online,
      rebase: rebase,
    );
    if (n == 0) return '“$branch” has nothing new for you — already up to date.';
    final what = n == 1 ? '1 commit' : '$n commits';
    return rebase
        ? 'Brought in $what from “$branch” and put your work on top.'
        : 'Brought in $what from “$branch”.';
  }, meta: {'strategy': rebase ? 'branch-rebase' : 'branch-merge'});

  /// Links [branch] to the same-named branch that already exists online.
  Future<ActionOutcome> linkUpstream(String branch, String remoteRef) =>
      _run(GitAction.link, null, () async {
        await _git.linkUpstream(repoPath, branch, remoteRef);
        return 'Linked “$branch” to $remoteRef — Pull and Push know where to go now.';
      });

  /// Puts [changes] back to the last commit (new files are removed).
  /// On success, [ActionOutcome.data] is the backup id for [undoRevert]
  /// (null if no backup was possible).
  Future<ActionOutcome> revertFiles(List<FileChange> changes) {
    final paths = <String>{
      for (final c in changes) ...[
        c.path,
        if (c.originalPath != null) c.originalPath!,
      ],
    }.toList();
    return _runWithData(GitAction.revert, () async {
      final backup = await _git.revert(repoPath, paths: paths);
      final what = changes.length == 1
          ? '“${p.basename(changes.first.path)}”'
          : plural(changes.length, 'file');
      return ('Reverted $what.', backup);
    });
  }

  /// Renames [from] to [to]; with [online], on GitHub/the remote too.
  Future<ActionOutcome> renameBranch(
    String from,
    String to, {
    bool online = false,
  }) => _run(GitAction.renameBranch, null, () async {
    await _git.renameBranchFully(repoPath, from, to, online: online);
    return online
        ? 'Renamed “$from” to “$to” here and online.'
        : 'Renamed “$from” to “$to”.';
  });

  // --- Changes put aside (the shelf) -------------------------------------------

  Future<ActionOutcome> shelve(String name, {List<String>? paths}) =>
      _run(GitAction.shelf, null, () async {
        await _git.stashPush(repoPath, name, paths: paths);
        return 'Put aside “$name”. Bring it back any time from the shelf.';
      });

  Future<ActionOutcome> unshelve(StashEntry entry, {bool keepCopy = false}) =>
      _run(GitAction.shelf, null, () async {
        await _git.stashApply(repoPath, entry.hash, keep: keepCopy);
        return keepCopy
            ? 'Brought back “${entry.message}” (a copy stays on the shelf).'
            : 'Brought back “${entry.message}”.';
      });

  Future<ActionOutcome> renameShelved(StashEntry entry, String name) =>
      _run(GitAction.shelf, null, () async {
        await _git.stashRename(repoPath, entry.hash, name);
        return 'Renamed to “$name”.';
      });

  Future<ActionOutcome> dropShelved(StashEntry entry) =>
      _run(GitAction.shelf, null, () async {
        await _git.stashDrop(repoPath, entry.hash);
        return 'Threw away “${entry.message}”.';
      });

  // --- Undo ------------------------------------------------------------------------

  /// Runs one undo step; [body] returns the message to show.
  Future<ActionOutcome> undo(Future<String> Function(GitService git) body) =>
      _run(GitAction.undo, null, () => body(_git));

  // --- Conflicts -----------------------------------------------------------------

  Future<ActionOutcome> resolveStep(Future<String> Function(GitService git) body) =>
      _run(GitAction.resolve, null, () => body(_git));

  /// Puts every change back to the last commit (new files are removed).
  Future<ActionOutcome> revertAll() =>
      _runWithData(GitAction.revert, () async {
        final backup = await _git.revert(repoPath);
        return ('Reverted all changes — back to your last commit.', backup);
      });

  /// Brings back what a revert put aside.
  Future<ActionOutcome> undoRevert(String backup) =>
      _run(GitAction.revert, null, () async {
        await _git.undoRevert(repoPath, backup);
        return 'Undone — your changes are back.';
      });

  /// Like [_run], but the body also returns data for the outcome.
  Future<ActionOutcome> _runWithData(
    GitAction action,
    Future<(String, Object?)> Function() body,
  ) async {
    Object? data;
    final outcome = await _run(action, null, () async {
      final (message, extra) = await body();
      data = extra;
      return message;
    });
    return outcome.ok ? ActionOutcome.success(outcome.message, data: data) : outcome;
  }

  Future<ActionOutcome> _run(
    GitAction action,
    AnalyticsEventType? track,
    Future<String> Function() body, {
    Map<String, dynamic> meta = const {},
  }) async {
    if (state != null) {
      return ActionOutcome.failure(
        const GittyException(
          'Hang on — Gitty is still finishing the previous step.',
        ),
      );
    }
    state = action;
    try {
      String message;
      try {
        message = await body();
      } on RepoLockedException {
        // Often another program (an IDE, a terminal) is mid-command and
        // finishes in a moment — try once more before bothering the user.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        message = await body();
      }
      if (track != null) {
        await ref
            .read(analyticsRepositoryProvider)
            .record(
              AnalyticsEvent(
                type: track,
                repoPath: repoPath,
                at: DateTime.now(),
                meta: meta,
              ),
            );
      }
      return ActionOutcome.success(message);
    } catch (error) {
      return ActionOutcome.failure(toGittyException(error));
    } finally {
      state = null;
      ref.invalidate(repoSnapshotProvider(repoPath));
      ref.invalidate(branchesProvider(repoPath));
      ref.invalidate(remotesProvider(repoPath));
      ref.invalidate(remoteHostProvider(repoPath));
      ref.invalidate(gitignoreProvider(repoPath));
      ref.invalidate(identityProvider(repoPath));
      ref.invalidate(branchTreeProvider(repoPath));
      ref.invalidate(parentSyncProvider(repoPath));
      ref.invalidate(stashesProvider(repoPath));
      ref.invalidate(branchSummariesProvider(repoPath));
      ref.invalidate(conflictStateProvider(repoPath));
    }
  }
}

final repoActionsProvider =
    NotifierProvider.family<RepoActionsController, GitAction?, String>(
      RepoActionsController.new,
    );

final branchesProvider = FutureProvider.autoDispose.family<BranchList, String>(
  (ref, path) => ref.watch(gitServiceProvider).branches(path),
);

/// Which branch grew from which, for the Switch branch dialog.
final branchTreeProvider = FutureProvider.autoDispose.family<BranchTree, String>(
  (ref, path) => ref.watch(gitServiceProvider).branchTree(path),
);

/// Where the repository lives online (GitHub, GitLab, …), for logos.
final remoteHostProvider = FutureProvider.autoDispose
    .family<RemoteHost?, String>((ref, path) async {
      ref.cacheFor(const Duration(minutes: 5));
      final git = ref.watch(gitServiceProvider);
      return repoRefreshLimiter.run(() async {
        if (!ref.mounted) throw const RefreshSkipped();
        if (!await git.isRepository(path)) return null;
        return git.remoteHost(path);
      });
    });

/// All branches for the Switch branch list, most recent first (fast).
final branchSummariesProvider = FutureProvider.autoDispose
    .family<List<BranchSummary>, String>(
      (ref, path) => ref.watch(gitServiceProvider).branchSummaries(path),
    );

/// Changes put aside ("the shelf"), newest first.
final stashesProvider = FutureProvider.autoDispose
    .family<List<StashEntry>, String>((ref, path) {
      ref.watch(
        repoSnapshotProvider(path).select(
          (s) => (s.value?.status.headOid, s.value?.status.changes.length),
        ),
      );
      return ref.watch(gitServiceProvider).stashes(path);
    });

/// What's clashing right now (merge/rebase/…), for the conflict resolver.
final conflictStateProvider = FutureProvider.autoDispose
    .family<ConflictState, String>((ref, path) {
      ref.watch(
        repoSnapshotProvider(path).select(
          (s) => (s.value?.status.conflictCount, s.value?.status.headOid),
        ),
      );
      return ref.watch(gitServiceProvider).conflictState(path);
    });

/// Remote names (e.g. `origin`) of a repository.
final remotesProvider = FutureProvider.autoDispose.family<List<String>, String>(
  (ref, path) => ref.watch(gitServiceProvider).remotes(path),
);

/// Who commits in this repository (name, email and where they're set).
final identityProvider = FutureProvider.autoDispose.family<GitIdentity, String>(
  (ref, path) => ref.watch(gitServiceProvider).identity(path),
);

/// The repository's .gitignore contents (null when there is none).
/// Re-read whenever the repository refreshes.
final gitignoreProvider = FutureProvider.autoDispose.family<String?, String>((
  ref,
  path,
) {
  ref.watch(repoSnapshotProvider(path));
  return ref.watch(gitServiceProvider).readGitignore(path);
});

/// Local, lightweight health metrics. Recomputed whenever the repo refreshes.
final repoInsightsProvider = Provider.autoDispose.family<RepoInsights, String>((
  ref,
  path,
) {
  ref.watch(repoSnapshotProvider(path));
  return ref.watch(analyticsRepositoryProvider).insightsFor(path);
});
