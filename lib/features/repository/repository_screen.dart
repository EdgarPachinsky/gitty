import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/gitty_exception.dart';
import '../../core/utils/time_ago.dart';
import '../../core/widgets/big_action_button.dart';
import '../../core/widgets/state_views.dart';
import '../../core/widgets/status_pill.dart';
import '../../services/ai/commit_message_service.dart';
import '../../services/ai/commit_style.dart';
import '../../services/git/git_models.dart';
import '../../services/service_providers.dart';
import '../../services/storage/analytics_repository.dart';
import '../dashboard/tracked_repos_controller.dart';
import '../settings/settings_controller.dart';
import '../sync/live_sync.dart';
import '../dashboard/repo_widgets.dart';
import '../history/history_screen.dart';
import 'add_remote_dialog.dart';
import 'gitignore_dialog.dart';
import 'repo_actions_controller.dart';
import 'repo_dialogs.dart';
import 'widgets/changes_panel.dart';
import 'widgets/changes_summary.dart';
import 'conflict_resolver.dart';
import 'pull_request_card.dart';
import 'widgets/git_identity_card.dart';
import 'widgets/gitignore_card.dart';
import 'widgets/init_repo_view.dart';
import 'widgets/insights_card.dart';
import 'widgets/parent_update_banner.dart';
import 'widgets/remote_setup_banner.dart';
import 'widgets/repo_lock_dialog.dart';
import 'widgets/revert_dialog.dart';
import 'widgets/shelf_card.dart';
import 'widgets/sync_banner.dart';

/// Everything for one repository: status, big action buttons, changes and
/// the commit box.
class RepositoryScreen extends ConsumerStatefulWidget {
  const RepositoryScreen({
    super.key,
    required this.repoPath,
    required this.onBack,
  });

  final String repoPath;
  final VoidCallback onBack;

  @override
  ConsumerState<RepositoryScreen> createState() => _RepositoryScreenState();
}

class _RepositoryScreenState extends ConsumerState<RepositoryScreen> {
  final _message = TextEditingController();
  final Set<String> _selected = {};
  late CommitStyle _style;
  bool _generating = false;
  String? _aiEngine;
  String? _aiNote;

  String get _path => widget.repoPath;

  @override
  void initState() {
    super.initState();
    final repo = ref
        .read(trackedReposProvider)
        .where((r) => r.path == _path)
        .firstOrNull;
    _style =
        repo?.preferredCommitStyle ??
        ref.read(settingsControllerProvider).defaultCommitStyle;
  }

  bool _warmedUp = false;

  /// Once something is staged, load the AI model in the background so
  /// "Generate with AI" answers quickly (local models load slowly).
  void _warmUpWhenStaged(RepoStatus status) {
    if (_warmedUp || status.stagedCount == 0) return;
    _warmedUp = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(commitMessageServiceProvider).warmUp());
    });
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  RepoActionsController get _actions =>
      ref.read(repoActionsProvider(_path).notifier);

  /// Shows the outcome of an action as a snackbar.
  ///
  /// [run] starts the action; it may run a second time if git was locked
  /// by a leftover lock file that the user chose to clear.
  Future<bool> _report(Future<ActionOutcome> Function() run) async {
    var outcome = await run();
    final locked = outcome.error;
    if (locked is RepoLockedException && mounted) {
      final cleared = await showRepoLockDialog(
        context,
        repoPath: _path,
        lockPath: locked.lockPath,
      );
      if (!cleared || !mounted) return false;
      outcome = await run();
    }
    if (mounted)
      showFriendlySnack(
        context,
        message: outcome.message,
        error: outcome.error,
      );
    return outcome.ok;
  }

  // --- Actions -----------------------------------------------------------------

  Future<void> _pull(RepoStatus status, {bool askAlways = false}) async {
    var strategy = PullStrategy.fastForwardOnly;
    if (askAlways || status.syncState == SyncState.diverged) {
      final chosen = await showPullOptionsDialog(context, status: status);
      if (chosen == null) return;
      strategy = chosen;
    }
    await _runOrShelve(
      status,
      'Pulling would overwrite some of your uncommitted changes. Put them '
      'aside, pull, then bring them back from the shelf.',
      () => _actions.pull(strategy),
    );
  }

  /// Runs [run]; if Git stops because uncommitted changes would be
  /// overwritten, offers to put them aside and then tries again.
  Future<bool> _runOrShelve(
    RepoStatus status,
    String reason,
    Future<ActionOutcome> Function() run,
  ) async {
    final first = await run();
    if (first.error is! LocalChangesException) {
      var used = false;
      return _report(() {
        if (used) return run();
        used = true;
        return Future.value(first);
      });
    }
    if (!mounted) return false;
    final name = await showPutAsideDialog(
      context,
      repoPath: _path,
      status: status,
      reason: reason,
    );
    if (!mounted) return false;
    if (name == null) {
      showFriendlySnack(context, message: first.message, error: first.error);
      return false;
    }
    if (!await _report(() => _actions.shelve(name))) return false;
    return _report(run);
  }

  Future<void> _putAside(RepoStatus status) async {
    final name = await showPutAsideDialog(
      context,
      repoPath: _path,
      status: status,
    );
    if (name != null) await _report(() => _actions.shelve(name));
  }

  /// Runs `git init`, then asks where the repository should live online.
  Future<void> _initRepository() async {
    final ok = await _report(() => _actions.initRepository());
    if (ok && mounted) await _addOrigin();
  }

  Future<void> _addOrigin() async {
    final message = await showAddRemoteDialog(context, repoPath: _path);
    if (message != null && mounted) {
      showFriendlySnack(context, message: message);
    }
  }

  Future<void> _editGitignore() async {
    final message = await showGitignoreDialog(context, repoPath: _path);
    if (message != null && mounted) {
      showFriendlySnack(context, message: message);
    }
  }

  /// Asks first, reverts, then offers "Undo" for a few seconds.
  Future<void> _revert(
    RepoStatus status,
    List<FileChange> changes, {
    required bool all,
  }) async {
    if (changes.isEmpty) return;
    final canUndo =
        status.hasCommits && !changes.any((c) => c.isConflicted);
    final ok = await confirmRevert(
      context,
      changes: changes,
      all: all,
      canUndo: canUndo,
    );
    if (!ok || !mounted) return;

    final outcome = all
        ? await _actions.revertAll()
        : await _actions.revertFiles(changes);
    if (!mounted) return;
    final backup = outcome.data;
    if (!outcome.ok || backup is! String) {
      showFriendlySnack(context, message: outcome.message, error: outcome.error);
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text(outcome.message),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _report(() => _actions.undoRevert(backup)),
          ),
        ),
      );
  }

  /// Push/Publish. Without any remote there's nowhere to push to yet, so
  /// offer to add origin instead of failing.
  Future<void> _push() async {
    List<String>? remotes;
    try {
      remotes = await ref.read(remotesProvider(_path).future);
    } catch (_) {
      // Let push report the real problem.
    }
    if (!mounted) return;
    if (remotes != null && remotes.isEmpty) {
      await _addOrigin();
      return;
    }
    await _report(() => _actions.push());
  }

  Future<void> _newBranch(RepoStatus status) async {
    final result = await showNewBranchDialog(
      context,
      repoPath: _path,
      fromBranch: status.branch,
    );
    if (result == null) return;
    await _runOrShelve(
      status,
      'Switching to the new branch would overwrite some of your uncommitted '
      'changes. Put them aside, create the branch, and bring them back '
      'whenever you like.',
      () => _actions.createBranch(
        result.name,
        from: result.from,
        switchToIt: result.switchToIt,
        push: result.push,
      ),
    );
  }

  Future<void> _switchBranch(RepoStatus status) async {
    final name = await showSwitchBranchDialog(
      context,
      repoPath: _path,
      status: status,
      onRename: (b) => _renameBranch(b.name, published: b.upstream != null),
    );
    if (name == null) return;
    await _runOrShelve(
      status,
      'Switching to “$name” would overwrite some of your uncommitted '
      'changes. Put them aside, switch, and bring them back whenever you '
      'like.',
      () => _actions.switchBranch(name),
    );
  }

  /// Brings another branch's changes into the current one.
  Future<void> _pullFromBranch(RepoStatus status) async {
    final choice = await showPullFromBranchDialog(
      context,
      repoPath: _path,
      status: status,
    );
    if (choice == null || !mounted) return;
    final (branch, online, rebase) = choice;
    await _runOrShelve(
      status,
      'Pulling from “$branch” would overwrite some of your uncommitted '
      'changes. Put them aside, pull, then bring them back from the shelf.',
      () => _actions.pullFromBranch(branch, online: online, rebase: rebase),
    );
  }

  /// Renames [branch] (optionally online too, when it's published).
  Future<void> _renameBranch(String branch, {required bool published}) async {
    final host = ref.read(remoteHostProvider(_path)).value;
    final online = !published
        ? null
        : host != null && host.kind != RemoteHostKind.localFolder
        ? host.label
        : 'the remote';
    final result = await showRenameBranchDialog(
      context,
      branch: branch,
      online: online,
    );
    if (result == null || !mounted) return;
    final (name, alsoOnline) = result;
    await _report(
      () => _actions.renameBranch(branch, name, online: alsoOnline),
    );
  }

  Future<void> _generateMessage(RepoStatus status) async {
    final staged = status.changes
        .where((c) => c.staged)
        .map((c) => c.path)
        .toList();
    if (staged.isEmpty) {
      showFriendlySnack(
        context,
        message: 'Stage some changes first so I know what to describe.',
      );
      return;
    }
    setState(() {
      _generating = true;
      _aiNote = null;
    });
    try {
      final git = ref.read(gitServiceProvider);
      final service = ref.read(commitMessageServiceProvider);
      final budget = service.maxDiffChars;
      final diff = budget > 0
          ? await git.stagedDiff(
              _path,
              maxChars: budget,
              perFileChars: (budget / 3).round(),
            )
          : '';
      final stat = await git.stagedDiffStat(_path);
      final result = await service.generate(
        CommitMessageRequest(
          diff: diff,
          diffStat: stat,
          stagedFiles: staged,
          style: _style,
          branch: status.branch,
          summary: ref
              .read(trackedReposProvider)
              .where((r) => r.path == _path)
              .firstOrNull
              ?.changesSummary,
        ),
        // Show the message as it's being written.
        onPartial: (text) {
          if (mounted && _generating) _message.text = text;
        },
      );
      await ref
          .read(analyticsRepositoryProvider)
          .record(
            AnalyticsEvent(
              type: AnalyticsEventType.aiMessageGenerated,
              repoPath: _path,
              at: DateTime.now(),
              meta: {'style': _style.name, 'engine': result.engine},
            ),
          );
      if (!mounted) return;
      setState(() {
        _message.text = result.message;
        _aiEngine = result.engine;
        _aiNote = result.note;
      });
    } catch (e) {
      final error = toGittyException(e);
      if (mounted)
        showFriendlySnack(context, message: error.message, error: error);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _commit(RepoStatus status) async {
    final message = _message.text.trim();
    if (message.isEmpty || status.stagedCount == 0) return;
    final leavesDirty = status.changes.any((c) => c.unstaged);
    var outcome = await _actions.commit(message, leavesDirtyTree: leavesDirty);

    // A leftover lock file blocked git: offer to clear it, then retry.
    final locked = outcome.error;
    if (locked is RepoLockedException && mounted) {
      final cleared = await showRepoLockDialog(
        context,
        repoPath: _path,
        lockPath: locked.lockPath,
      );
      if (!cleared || !mounted) return;
      outcome = await _actions.commit(message, leavesDirtyTree: leavesDirty);
    }

    // Git doesn't know who's committing: ask (saved for this repo only),
    // then commit straight away.
    if (outcome.error is MissingIdentityException && mounted) {
      final saved = await showIdentityDialog(
        context,
        repoPath: _path,
        reason:
            'Before your first commit here, tell Git who you are. It’s saved '
            'only for this repository — nothing global changes.',
      );
      if (saved == null || !mounted) return;
      outcome = await _actions.commit(message, leavesDirtyTree: leavesDirty);
    }
    if (!mounted) return;
    showFriendlySnack(context, message: outcome.message, error: outcome.error);
    final ok = outcome.ok;
    if (ok && mounted) {
      setState(() {
        _message.clear();
        _aiEngine = null;
        _aiNote = null;
      });
    }
  }

  void _setStyle(CommitStyle style) {
    setState(() => _style = style);
    ref.read(trackedReposProvider.notifier).setPreferredStyle(_path, style);
  }

  Future<void> _launch(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      final error = toGittyException(e);
      if (mounted)
        showFriendlySnack(context, message: error.message, error: error);
    }
  }

  // --- UI ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(repoSnapshotProvider(_path));
    final busy = ref.watch(repoActionsProvider(_path));
    // Live: react to file changes and teammates' pushes while open.
    ref.watch(repoWatchProvider(_path));
    ref.watch(liveRemoteSyncProvider(_path));

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              repoPath: _path,
              title:
                  ref
                      .watch(trackedReposProvider)
                      .where((r) => r.path == _path)
                      .firstOrNull
                      ?.title ??
                  p.basename(_path),
              status: snapshot.value?.status,
              remoteBranch: snapshot.value?.remoteBranch,
              onCopyBranch: (branch) async {
                await Clipboard.setData(ClipboardData(text: branch));
                if (mounted) {
                  showFriendlySnack(context, message: 'Copied “$branch”.');
                }
              },
              onRename: () {
                final repo = ref
                    .read(trackedReposProvider)
                    .where((r) => r.path == _path)
                    .firstOrNull;
                if (repo != null) showRenameRepoDialog(context, ref, repo);
              },
              refreshing: snapshot.isLoading,
              onBack: widget.onBack,
              onRefresh: () => ref.invalidate(repoSnapshotProvider(_path)),
              onHistory: () => HistoryScreen.open(
                context,
                _path,
                ref
                        .read(trackedReposProvider)
                        .where((r) => r.path == _path)
                        .firstOrNull
                        ?.title ??
                    p.basename(_path),
              ),
              onBranchTap: snapshot.value == null
                  ? null
                  : () => _switchBranch(snapshot.value!.status),
              onRenameBranch: snapshot.value?.status.branch == null
                  ? null
                  : () => _renameBranch(
                      snapshot.value!.status.branch!,
                      published: snapshot.value!.status.upstream != null,
                    ),
              onOpenTerminal: () => _launch(
                () => ref.read(systemLauncherProvider).openTerminal(_path),
              ),
              onOpenVsCode: () => _launch(
                () => ref.read(systemLauncherProvider).openInVsCode(_path),
              ),
              onReveal: () => _launch(
                () =>
                    ref.read(systemLauncherProvider).revealInFileManager(_path),
              ),
              onRemove: () =>
                  ref.read(trackedReposProvider.notifier).remove(_path),
            ),
            Expanded(
              child: switch (snapshot) {
                AsyncValue(:final value?) => _buildBody(value, busy),
                AsyncValue(:final error?) when error is NotARepositoryException =>
                  InitRepositoryView(
                    folderPath: _path,
                    busy: busy == GitAction.init,
                    onInit: _initRepository,
                  ),
                AsyncValue(:final error?) => ErrorView(
                  error: error,
                  onRetry: () => ref.invalidate(repoSnapshotProvider(_path)),
                ),
                _ => const LoadingView(message: 'Reading repository…'),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(RepoSnapshot snapshot, GitAction? busy) {
    final status = snapshot.status;
    _warmUpWhenStaged(status);

    // Keep the selection in sync with what's actually unstaged.
    final unstagedPaths = status.changes
        .where((c) => c.unstaged)
        .map((c) => c.path)
        .toSet();
    _selected.retainAll(unstagedPaths);

    final actions = _ActionGrid(
      status: status,
      remoteHost: ref.watch(remoteHostProvider(_path)).value,
      busy: busy,
      onFetch: () => _report(() => _actions.fetch()),
      onPull: () => _pull(status),
      onPush: _push,
      onNewBranch: () => _newBranch(status),
      onSwitchBranch: () => _switchBranch(status),
      onPullFromBranch: () => _pullFromBranch(status),
    );

    final changes = ChangesPanel(
      status: status,
      selected: _selected,
      busy: busy,
      onToggle: (path, value) =>
          setState(() => value ? _selected.add(path) : _selected.remove(path)),
      onStageAll: () => _report(() => _actions.stageAll()),
      onStageSelected: () => _report(() => _actions.stage(_selected.toList())),
      onStageOne: (change) => _report(() => _actions.stage([change.path])),
      onUnstageOne: (change) => _report(
        () => _actions.unstage([
          change.path,
          if (change.originalPath != null) change.originalPath!,
        ]),
      ),
      onUnstageAll: () => _report(() => _actions.unstageAll()),
      onRevertAll: () => _revert(status, status.changes, all: true),
      onRevertOne: (change) => _revert(status, [change], all: false),
      summary: ChangesSummaryBox(
        repoPath: _path,
        status: status,
        onUseAsMessage: (text) {
          _message.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
        },
      ),
      onResolveConflicts: () => ConflictResolverScreen.open(context, _path),
    );

    final commit = _CommitPanel(
      status: status,
      controller: _message,
      style: _style,
      generating: _generating,
      committing: busy == GitAction.commit,
      aiEngine: _aiEngine,
      aiNote: _aiNote,
      onStyleChanged: _setStyle,
      onGenerate: () => _generateMessage(status),
      onCommit: () => _commit(status),
      onStageAll: () => _report(() => _actions.stageAll()),
    );

    final shelf = ShelfCard(
      repoPath: _path,
      status: status,
      busy: busy != null,
      onPutAside: () => _putAside(status),
      report: _report,
    );

    final gitignoreCard = GitignoreCard(
      repoPath: _path,
      onOpen: _editGitignore,
    );

    final syncReminders = ref.watch(
      settingsControllerProvider.select((s) => s.syncReminders),
    );
    final hasNoRemote = ref.watch(remotesProvider(_path)).value?.isEmpty ?? false;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 980;
        return ListView(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
          children: [
            if (hasNoRemote)
              RemoteSetupBanner(busy: busy != null, onAddOrigin: _addOrigin),
            ParentUpdateBanner(
              repoPath: _path,
              busy: busy != null,
              onBringIn: (sync) async {
                final ok = await _report(
                  () => _actions.bringInParent(sync.parentRef, label: sync.parent),
                );
                if (ok) {
                  ref
                      .read(remoteUpdatesProvider.notifier)
                      .dismissFor(_path, sync.parentRef);
                }
              },
            ),
            if (syncReminders)
              SyncBanner(
                status: status,
                busy: busy != null,
                onPull: (strategy) => _runOrShelve(
                  status,
                  'Pulling would overwrite some of your uncommitted changes. '
                  'Put them aside, pull, then bring them back from the shelf.',
                  () => _actions.pull(strategy),
                ),
                onChoosePull: () => _pull(status, askAlways: true),
                onPush: _push,
                onSwitchBranch: () => _switchBranch(status),
                remoteBranch: snapshot.remoteBranch,
                onLink: status.branch == null || snapshot.remoteBranch == null
                    ? null
                    : () => _report(
                        () => _actions.linkUpstream(
                          status.branch!,
                          snapshot.remoteBranch!,
                        ),
                      ),
              ),
            actions,
            const SizedBox(height: 20),
            PullRequestCard(repoPath: _path, status: status, onPublish: _push),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: changes),
                  const SizedBox(width: 20),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        commit,
                        const SizedBox(height: 20),
                        shelf, // adds its own gap when shown
                        GitIdentityCard(repoPath: _path),
                        const SizedBox(height: 20),
                        gitignoreCard,
                        const SizedBox(height: 20),
                        InsightsCard(repoPath: _path),
                      ],
                    ),
                  ),
                ],
              )
            else ...[
              commit,
              const SizedBox(height: 20),
              changes,
              const SizedBox(height: 20),
              shelf, // adds its own gap when shown
              GitIdentityCard(repoPath: _path),
              const SizedBox(height: 20),
              gitignoreCard,
              const SizedBox(height: 20),
              InsightsCard(repoPath: _path),
            ],
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.repoPath,
    required this.title,
    required this.status,
    required this.remoteBranch,
    required this.onCopyBranch,
    required this.onRename,
    required this.refreshing,
    required this.onBack,
    required this.onRefresh,
    required this.onHistory,
    required this.onBranchTap,
    required this.onRenameBranch,
    required this.onOpenTerminal,
    required this.onOpenVsCode,
    required this.onReveal,
    required this.onRemove,
  });

  final String repoPath;

  /// Title shown in Gitty (custom name or folder name).
  final String title;
  final RepoStatus? status;
  final String? remoteBranch;
  final ValueChanged<String> onCopyBranch;
  final VoidCallback onRename;
  final bool refreshing;
  final VoidCallback onBack;
  final VoidCallback onRefresh;
  final VoidCallback onHistory;
  final VoidCallback? onBranchTap;

  /// Renames the current branch (null when not on a branch).
  final VoidCallback? onRenameBranch;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenVsCode;
  final VoidCallback onReveal;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final revealLabel = Platform.isMacOS
        ? 'Show in Finder'
        : Platform.isWindows
        ? 'Show in Explorer'
        : 'Show in Files';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 20, 12),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to repositories',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Wraps onto a second line when the window (or the help
                // panel) leaves little room, instead of overflowing.
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RemoteHostLogo(repoPath: repoPath, size: 20),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            title,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (status != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: ActionChip(
                            avatar: const Icon(
                              Icons.call_split_rounded,
                              size: 16,
                            ),
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 220),
                              child: Text(
                                status!.branch ?? 'detached HEAD',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            tooltip: status!.branch == null
                                ? 'Switch branch'
                                : 'Switch branch (on ${status!.branch})',
                            onPressed: onBranchTap,
                            ),
                          ),
                          if (status!.branch != null)
                            IconButton(
                              tooltip: 'Copy branch name',
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              icon: const Icon(Icons.copy_rounded),
                              onPressed: () => onCopyBranch(status!.branch!),
                            ),
                          if (onRenameBranch != null)
                            IconButton(
                              tooltip: 'Rename branch',
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              icon: const Icon(
                                Icons.drive_file_rename_outline_rounded,
                              ),
                              onPressed: onRenameBranch,
                            ),
                        ],
                      ),
                    if (status != null)
                      SyncStatusPill(status: status!, remoteBranch: remoteBranch),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  repoPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'History — what happened here',
            onPressed: onHistory,
            icon: const Icon(Icons.history_rounded),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: refreshing ? null : onRefresh,
            icon: refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Open in terminal',
            onPressed: onOpenTerminal,
            icon: const Icon(Icons.terminal_rounded),
          ),
          IconButton(
            tooltip: 'Open in VS Code',
            onPressed: onOpenVsCode,
            icon: const Icon(Icons.code_rounded),
          ),
          PopupMenuButton<VoidCallback>(
            tooltip: 'More',
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              if (onRenameBranch != null)
                PopupMenuItem(
                  value: onRenameBranch!,
                  child: const Text('Rename branch…'),
                ),
              PopupMenuItem(
                value: onRename,
                child: const Text('Rename repository in Gitty…'),
              ),
              PopupMenuItem(value: onReveal, child: Text(revealLabel)),
              PopupMenuItem(
                value: () => Clipboard.setData(ClipboardData(text: repoPath)),
                child: const Text('Copy path'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: onRemove,
                child: const Text('Remove from Gitty'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionGrid extends StatelessWidget {
  const _ActionGrid({
    required this.status,
    required this.remoteHost,
    required this.busy,
    required this.onFetch,
    required this.onPull,
    required this.onPush,
    required this.onNewBranch,
    required this.onSwitchBranch,
    required this.onPullFromBranch,
  });

  final RepoStatus status;

  /// Where the repository lives online (for "from GitHub" wording).
  final RemoteHost? remoteHost;
  final GitAction? busy;
  final VoidCallback onFetch;
  final VoidCallback onPull;
  final VoidCallback onPush;
  final VoidCallback onNewBranch;
  final VoidCallback onSwitchBranch;
  final VoidCallback onPullFromBranch;

  @override
  Widget build(BuildContext context) {
    final idle = busy == null;
    final state = status.syncState;
    final canPush = !status.isDetached && status.hasCommits;

    // Plain words for "where": "GitHub" rather than "origin", so newcomers
    // know exactly what each button talks to.
    final host = remoteHost;
    final upstream = status.upstream; // e.g. origin/main
    final upstreamRemote = upstream?.split('/').first;
    final hostMatches =
        host != null &&
        host.kind != RemoteHostKind.localFolder &&
        (upstreamRemote == null || host.remoteName == upstreamRemote);
    final place = hostMatches
        ? host!.label
        : upstreamRemote ?? host?.remoteName ?? 'the online copy';
    final placeExact = upstream == null ? place : '$place ($upstream)';
    final branch = status.branch == null ? 'this branch' : '“${status.branch}”';
    final behind = status.behind;
    final ahead = status.ahead;

    final buttons = [
      BigActionButton(
        icon: Icons.cloud_sync_outlined,
        label: 'Fetch',
        command: 'git fetch --all --prune',
        caption: host == null && upstream == null
            ? 'Check online for news. Changes nothing.'
            : 'See what’s new on $place. Changes nothing.',
        help:
            'Asks $place what’s new (commits and branches others pushed),\n'
            'so Gitty can show whether you’re behind.\n'
            'It only downloads information — your files, branches and\n'
            'commits stay exactly as they are. Always safe.',
        busy: busy == GitAction.fetch,
        onPressed: idle ? onFetch : null,
      ),
      BigActionButton(
        icon: Icons.download_rounded,
        label: 'Pull',
        command: state == SyncState.diverged
            ? 'git pull --rebase'
            : 'git pull --ff-only',
        caption: upstream == null
            ? 'Not linked to an online copy yet'
            : state == SyncState.diverged
            ? 'Combine $place’s commits with yours'
            : behind > 0
            ? 'Bring ${plural(behind, 'new commit')} from $place into your files'
            : 'Bring new commits from $place into your files',
        badge: behind > 0 ? '$behind' : null,
        emphasized: state == SyncState.behind || state == SyncState.diverged,
        busy: busy == GitAction.pull,
        onPressed: idle && upstream != null ? onPull : null,
        help: upstream == null
            ? '$branch only exists on this computer so far,\n'
                  'so there’s nothing to download yet.'
            : state == SyncState.diverged
            ? 'You and $place both have new commits on $branch.\n'
                  'Pull downloads theirs from $placeExact and combines them\n'
                  'with yours — you’ll choose how in the next step.\n'
                  'Nothing is uploaded, and your uncommitted edits are kept.'
            : 'Downloads new commits from $placeExact and adds them to\n'
                  'your $branch branch, so the files in this folder update\n'
                  'to the latest version.\n'
                  'Your uncommitted edits are kept. If something can’t be\n'
                  'combined safely, Git stops and nothing changes.',
      ),
      BigActionButton(
        icon: Icons.upload_rounded,
        label: state == SyncState.noUpstream ? 'Publish' : 'Push',
        command: state == SyncState.noUpstream
            ? 'git push -u ${upstreamRemote ?? host?.remoteName ?? 'origin'} '
                  '${status.branch ?? '<branch>'}'
            : 'git push',
        caption: state == SyncState.noUpstream
            ? (host == null
                  ? 'Put this branch online'
                  : 'Put this branch on $place')
            : ahead > 0
            ? 'Upload your ${plural(ahead, 'commit')} to $place'
            : 'Upload your commits to $place',
        badge: ahead > 0 ? '$ahead' : null,
        emphasized: state == SyncState.ahead,
        busy: busy == GitAction.push,
        onPressed: idle && canPush ? onPush : null,
        help: status.isDetached
            ? 'You’re not on a branch right now.\n'
                  'Switch to a branch first, then you can upload.'
            : !status.hasCommits
            ? 'Make your first commit, then you can upload it.'
            : state == SyncState.noUpstream
            ? (host == null
                  ? 'This repository isn’t online yet — Gitty will first ask\n'
                        'where to put it (for example GitHub).\n'
                        'Then $branch and its commits are uploaded there.\n'
                        'Nothing on this computer changes.'
                  : 'Creates $branch on $place and uploads its commits,\n'
                        'so it’s backed up and others can see it.\n'
                        'Nothing on this computer changes.')
            : 'Uploads the commits you made on $branch to $placeExact,\n'
                  'so others (and your other computers) can see them.\n'
                  'Only committed work is sent — uncommitted edits stay here.\n'
                  'Nothing on this computer changes. If $place has newer\n'
                  'commits, Git asks you to pull first.',
      ),
      BigActionButton(
        icon: Icons.add_road_rounded,
        label: 'New branch',
        command: 'git switch -c <new-branch>',
        caption: 'Start something new safely',
        help: status.hasCommits
            ? 'Makes a new branch starting from where $branch is now,\n'
                  'and switches to it. Your files — including uncommitted\n'
                  'edits — stay exactly as they are, and $branch isn’t touched.\n'
                  'Great for trying something without risk. Nothing is uploaded.'
            : 'Make your first commit before creating branches.',
        busy: busy == GitAction.createBranch,
        onPressed: idle && status.hasCommits ? onNewBranch : null,
      ),
      BigActionButton(
        icon: Icons.alt_route_rounded,
        label: 'Switch branch',
        command: 'git switch <branch>',
        caption: status.branch == null
            ? 'Pick a branch'
            : 'On ${status.branch}',
        help:
            'Changes the files in this folder to another branch’s version.\n'
            'Uncommitted edits come along with you; if they’d clash with\n'
            'the other branch, Git stops and nothing changes.\n'
            'Nothing is lost or uploaded — you can always switch back.',
        busy: busy == GitAction.switchBranch,
        onPressed: idle ? onSwitchBranch : null,
      ),
      BigActionButton(
        icon: Icons.call_merge_rounded,
        label: 'Pull from branch',
        caption: status.branch == null
            ? 'Bring another branch’s changes in'
            : 'Bring another branch’s changes into ${status.branch}',
        command: 'git pull origin <branch>',
        help:
            'Pick any branch (for example main or dev) and bring its latest\n'
            'changes into $branch — handy when your branch has fallen behind.\n'
            'By default its newest online version is downloaded first.\n'
            'Your own commits and files stay; if something clashes, Gitty\n'
            'lets you pick what to keep. Nothing is uploaded.',
        busy: busy == GitAction.merge,
        onPressed: idle && canPush ? onPullFromBranch : null,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Six cards: one row when wide, otherwise tidy rows of 3 or 2.
        final columns = constraints.maxWidth >= 1080
            ? 6
            : (constraints.maxWidth >= 560 ? 3 : 2);
        // A fixed height (rather than an aspect ratio, which forgets the
        // spacing) so two-line captions always fit.
        return GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            mainAxisExtent: 158,
          ),
          children: buttons,
        );
      },
    );
  }
}

class _CommitPanel extends StatelessWidget {
  const _CommitPanel({
    required this.status,
    required this.controller,
    required this.style,
    required this.generating,
    required this.committing,
    required this.aiEngine,
    required this.aiNote,
    required this.onStyleChanged,
    required this.onGenerate,
    required this.onCommit,
    required this.onStageAll,
  });

  final RepoStatus status;
  final TextEditingController controller;
  final CommitStyle style;
  final bool generating;
  final bool committing;
  final String? aiEngine;
  final String? aiNote;
  final ValueChanged<CommitStyle> onStyleChanged;
  final VoidCallback onGenerate;
  final VoidCallback onCommit;
  final VoidCallback onStageAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final staged = status.stagedCount;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('Commit', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Text(
                  staged == 0
                      ? 'nothing staged'
                      : '${plural(staged, 'file')} staged',
                  style: muted,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in CommitStyle.values)
                  Tooltip(
                    message: s.example,
                    child: ChoiceChip(
                      label: Text(s.label),
                      selected: s == style,
                      onSelected: (_) => onStyleChanged(s),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final canCommit =
                    staged > 0 && value.text.trim().isNotEmpty && !committing;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CallbackShortcuts(
                      bindings: {
                        const SingleActivator(
                          LogicalKeyboardKey.enter,
                          meta: true,
                        ): () {
                          if (canCommit) onCommit();
                        },
                        const SingleActivator(
                          LogicalKeyboardKey.enter,
                          control: true,
                        ): () {
                          if (canCommit) onCommit();
                        },
                      },
                      child: TextField(
                        controller: controller,
                        minLines: 4,
                        maxLines: 10,
                        enabled: !generating,
                        decoration: const InputDecoration(
                          hintText: 'Describe what you changed…',
                        ),
                      ),
                    ),
                    if (aiEngine != null || aiNote != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.auto_awesome,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              [
                                if (aiEngine != null)
                                  'Written by $aiEngine — feel free to edit.',
                                if (aiNote != null) aiNote!,
                              ].join(' '),
                              style: muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: generating || staged == 0
                              ? null
                              : onGenerate,
                          icon: generating
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.auto_awesome_outlined,
                                  size: 18,
                                ),
                          label: Text(
                            generating ? 'Thinking…' : 'Generate with AI',
                          ),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: canCommit ? onCommit : null,
                          icon: committing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.check_rounded, size: 18),
                          label: const Text('Commit'),
                        ),
                      ],
                    ),
                    if (staged == 0 && !status.isClean) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Stage the files you want to include first.',
                              style: muted,
                            ),
                          ),
                          TextButton(
                            onPressed: onStageAll,
                            child: const Text('Stage all'),
                          ),
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
