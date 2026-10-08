import 'dart:io';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/gitty_exception.dart';
import '../../core/utils/time_ago.dart';
import '../../core/widgets/state_views.dart';
import '../../core/widgets/status_pill.dart';
import '../../services/git/git_models.dart';
import '../../services/storage/repo_repository.dart';
import '../../services/service_providers.dart';
import '../repository/repo_actions_controller.dart';
import '../settings/settings_controller.dart';
import '../sync/live_sync.dart';
import 'add_repo_actions.dart';
import 'repo_widgets.dart';
import 'tracked_repos_controller.dart';

/// Overview of all tracked repositories with their sync status.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key, required this.onOpen});

  final ValueChanged<String> onOpen;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  /// Host filter (empty = show all). `null` stands for "no remote".
  final Set<RemoteHostKind?> _hosts = {};

  ValueChanged<String> get onOpen => widget.onOpen;

  bool get _filtering => _query.trim().isNotEmpty || _hosts.isNotEmpty;

  void _clearFilters() => setState(() {
    _search.clear();
    _query = '';
    _hosts.clear();
  });

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Matches the title, folder name, path, hosting service and branch.
  bool _matches(TrackedRepo repo, _HostIndex hosts) {
    if (_hosts.isNotEmpty) {
      if (!hosts.kinds.containsKey(repo.path)) return false; // still loading
      if (!_hosts.contains(hosts.kinds[repo.path])) return false;
    }
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final host = ref.read(remoteHostProvider(repo.path)).value;
    // Only look at statuses already loaded; searching shouldn't start git.
    final snapshot = repoSnapshotProvider(repo.path);
    final branch = ref.exists(snapshot)
        ? ref.read(snapshot).value?.status.branch
        : null;
    return [
      repo.title,
      repo.name,
      repo.path,
      if (host != null) host.label,
      if (host?.webUrl != null) host!.webUrl.toString(),
      if (branch != null) branch,
    ].any((field) => field.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final allRepos = ref.watch(trackedReposProvider);
    // Which hosting service each repo uses (for the filter buttons). Only
    // rebuilds this screen when a host actually changes.
    final hosts = ref.watch(_hostIndexProvider);
    final hostCounts = <RemoteHostKind?, int>{};
    for (final kind in hosts.kinds.values) {
      hostCounts[kind] = (hostCounts[kind] ?? 0) + 1;
    }
    _hosts.removeWhere((k) => !hostCounts.containsKey(k));
    final repos = allRepos.where((r) => _matches(r, hosts)).toList();
    final theme = Theme.of(context);

    _hostCounts = hostCounts;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
            _searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            _searchFocus.requestFocus(),
      },
      child: Focus(
        autofocus: true,
        child: _buildScaffold(context, theme, allRepos, repos),
      ),
    );
  }

  Map<RemoteHostKind?, int> _hostCounts = const {};

  /// The small host filter buttons shown next to the title, or null when
  /// no host is known yet.
  Widget? _hostFilters() {
    final kinds = [
      for (final k in [...RemoteHostKind.values, null])
        if (_hostCounts.containsKey(k)) k,
    ];
    if (kinds.isEmpty) return null;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final k in kinds)
          _HostFilterButton(
            kind: k,
            count: _hostCounts[k]!,
            selected: _hosts.contains(k),
            onTap: () => setState(
              () => _hosts.contains(k) ? _hosts.remove(k) : _hosts.add(k),
            ),
          ),
      ],
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    ThemeData theme,
    List<TrackedRepo> allRepos,
    List<TrackedRepo> repos,
  ) {
    // Remembered expanded/collapsed state of the Pinned / Other panels.
    // (Only these two settings — other settings don't rebuild the grid.)
    final (pinnedExpanded, otherExpanded) = ref.watch(
      settingsControllerProvider.select(
        (s) => (s.pinnedSectionExpanded, s.otherSectionExpanded),
      ),
    );
    final settingsCtl = ref.read(settingsControllerProvider.notifier);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Your repositories',
                              style: theme.textTheme.headlineSmall,
                            ),
                            if (_hostFilters() case final filters?) ...[
                              const SizedBox(width: 16),
                              Flexible(child: filters),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          allRepos.isEmpty
                              ? 'Let’s add your first one.'
                              : !_filtering
                              ? plural(
                                  allRepos.length,
                                  'repository',
                                  'repositories',
                                )
                              : _query.trim().isEmpty
                              ? '${repos.length} of ${allRepos.length} shown'
                              : '${repos.length} of ${allRepos.length} match “${_query.trim()}”',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (allRepos.isNotEmpty)
                    IconButton(
                      tooltip: 'Refresh all',
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: () => ref.invalidate(repoSnapshotProvider),
                    ),
                  const SizedBox(width: 4),
                  _AddMenuButton(),
                ],
              ),
              const SizedBox(height: 16),
              if (allRepos.isNotEmpty) ...[
                TextField(
                  controller: _search,
                  focusNode: _searchFocus,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText:
                        'Search by name, folder, branch or host  '
                        '(${Platform.isMacOS ? '⌘F' : 'Ctrl+F'})',
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => setState(() {
                              _search.clear();
                              _query = '';
                            }),
                          ),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 16),
              ],
              if (allRepos.isNotEmpty) _SyncSummaryBanner(repos: allRepos),
              Expanded(
                child: allRepos.isNotEmpty && repos.isEmpty
                    ? EmptyState(
                        icon: Icons.search_off_rounded,
                        title: _query.trim().isEmpty
                            ? 'No repositories from those hosts'
                            : 'Nothing matches “${_query.trim()}”',
                        message: _query.trim().isEmpty
                            ? 'Pick another host above, or show everything.'
                            : 'Try part of the name, the folder, a branch, or '
                                  '“GitHub” / “GitLab”.',
                        actions: [
                          OutlinedButton(
                            onPressed: _clearFilters,
                            child: Text(
                              _hosts.isEmpty ? 'Clear search' : 'Show everything',
                            ),
                          ),
                        ],
                      )
                    : repos.isEmpty
                    ? EmptyState(
                        icon: Icons.folder_open_rounded,
                        title: 'No repositories yet',
                        message:
                            'Add a folder you already work in, let me look for repositories, or clone a new one.',
                        actions: [
                          FilledButton.icon(
                            onPressed: () => pickAndAddRepository(context, ref),
                            icon: const Icon(Icons.create_new_folder_outlined),
                            label: const Text('Add a folder'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => showScanDialog(context),
                            icon: const Icon(Icons.travel_explore),
                            label: const Text('Find repositories'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => showCloneDialog(context),
                            icon: const Icon(Icons.download_rounded),
                            label: const Text('Clone'),
                          ),
                        ],
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final columns = (constraints.maxWidth / 360)
                              .floor()
                              .clamp(1, 4);
                          final pinned = repos.where((r) => r.pinned).toList();
                          final others = repos.where((r) => !r.pinned).toList();

                          Widget grid(List<TrackedRepo> list) =>
                              SliverGrid.builder(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      mainAxisExtent: 168,
                                      crossAxisSpacing: 16,
                                      mainAxisSpacing: 16,
                                    ),
                                itemCount: list.length,
                                itemBuilder: (context, i) => _DraggableRepoCard(
                                  key: ValueKey(list[i].path),
                                  repo: list[i],
                                  // Order is saved for the full list, so
                                  // no dragging while it's filtered.
                                  canDrag: !_filtering && list.length > 1,
                                  onOpen: () => onOpen(list[i].path),
                                ),
                              );

                          // Pinned on top, everything else below, each an
                          // expandable panel that remembers its state.
                          // Without pins it's the plain grid, as before.
                          final pinnedOpen = pinnedExpanded;
                          final othersOpen = pinned.isEmpty || otherExpanded;
                          return CustomScrollView(
                            slivers: [
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 4),
                              ),
                              if (pinned.isNotEmpty) ...[
                                SliverToBoxAdapter(
                                  child: _SectionHeader(
                                    icon: Icons.push_pin_rounded,
                                    title: 'Pinned',
                                    count: pinned.length,
                                    expanded: pinnedOpen,
                                    onToggle: () => settingsCtl.change(
                                      (c) => c.copyWith(
                                        pinnedSectionExpanded: !pinnedOpen,
                                      ),
                                    ),
                                  ),
                                ),
                                if (pinnedOpen) grid(pinned),
                                if (others.isNotEmpty)
                                  SliverToBoxAdapter(
                                    child: _SectionHeader(
                                      icon: Icons.folder_copy_outlined,
                                      title: 'All other repositories',
                                      count: others.length,
                                      topPadding: pinnedOpen ? 24 : 8,
                                      expanded: othersOpen,
                                      onToggle: () => settingsCtl.change(
                                        (c) => c.copyWith(
                                          otherSectionExpanded: !othersOpen,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                              if (others.isNotEmpty && othersOpen)
                                grid(others),
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 28),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddMenuButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuAnchor(
      alignmentOffset: const Offset(-120, 4),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.create_new_folder_outlined),
          onPressed: () => pickAndAddRepository(context, ref),
          child: const Text('Add a folder…'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.travel_explore),
          onPressed: () => showScanDialog(context),
          child: const Text('Find repositories…'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.download_rounded),
          onPressed: () => showCloneDialog(context),
          child: const Text('Clone…'),
        ),
      ],
      builder: (context, controller, _) => FilledButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
    );
  }
}

/// Gentle, non-blocking reminder when repositories are behind/diverged.
class _SyncSummaryBanner extends ConsumerWidget {
  const _SyncSummaryBanner({required this.repos});

  final List<TrackedRepo> repos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(
      settingsControllerProvider.select((s) => s.syncReminders),
    );
    if (!enabled) return const SizedBox.shrink();

    var behind = 0;
    var diverged = 0;
    for (final repo in repos) {
      final state = ref.watch(
        repoSnapshotProvider(
          repo.path,
        ).select((s) => s.value?.status.syncState),
      );
      if (state == SyncState.behind) behind++;
      if (state == SyncState.diverged) diverged++;
    }
    if (behind == 0 && diverged == 0) return const SizedBox.shrink();

    final parts = [
      if (behind > 0)
        '${plural(behind, 'repository', 'repositories')} ${behind == 1 ? 'is' : 'are'} behind',
      if (diverged > 0) '$diverged diverged',
    ];
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              Icons.lightbulb_outline,
              color: scheme.onSecondaryContainer,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${parts.join(' and ')}. Pulling early keeps merges small and painless.',
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One repository on the dashboard.
class RepoCard extends ConsumerWidget {
  const RepoCard({
    super.key,
    required this.repo,
    required this.onOpen,
    this.dragHandle,
  });

  final TrackedRepo repo;
  final VoidCallback onOpen;

  /// Shown at the start of the title row, for reordering.
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final snapshot = ref.watch(repoSnapshotProvider(repo.path));
    // Keep the card in sync with Git activity in the folder (commits,
    // branch switches, fetches…). The repository screen watches every file.
    ref.watch(repoGitWatchProvider(repo.path));

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (dragHandle != null) dragHandle!,
                  RemoteHostLogo(repoPath: repo.path, size: 16),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      repo.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (snapshot.value != null)
                    SyncStatusPill(
                      status: snapshot.value!.status,
                      remoteBranch: snapshot.value!.remoteBranch,
                    ),
                  IconButton(
                    tooltip: repo.pinned ? 'Unpin' : 'Pin to top',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    isSelected: repo.pinned,
                    icon: const Icon(Icons.push_pin_outlined),
                    selectedIcon: Icon(
                      Icons.push_pin_rounded,
                      color: theme.colorScheme.primary,
                    ),
                    onPressed: () => ref
                        .read(trackedReposProvider.notifier)
                        .togglePin(repo.path),
                  ),
                  _RepoCardMenu(repo: repo, onOpen: onOpen),
                ],
              ),
              const SizedBox(height: 2),
              Tooltip(
                message: repo.path,
                waitDuration: const Duration(milliseconds: 600),
                child: Text(
                  // With a custom title the folder name stays out of sight.
                  repo.displayName == null
                      ? repo.path
                      : 'in ${p.dirname(repo.path)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Spacer(),
              switch (snapshot) {
                AsyncValue(:final value?) => _SnapshotDetails(snapshot: value),
                AsyncValue(:final error?) when error is NotARepositoryException =>
                  _NotInitializedDetails(onSetUp: onOpen),
                AsyncValue(:final error?) => _CardError(
                  error: error,
                  repo: repo,
                ),
                _ => const LinearProgressIndicator(minHeight: 2),
              },
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny toggle: host logo + how many repos use it. Several can be on at
/// once; none on means "show all".
class _HostFilterButton extends StatelessWidget {
  const _HostFilterButton({
    required this.kind,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final RemoteHostKind? kind;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    final label = remoteHostFilterLabel(kind);
    return Tooltip(
      message: selected
          ? '$label · $count — click to stop filtering by it'
          : '$label · $count — click to show only these',
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected
                ? scheme.primary
                : scheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                remoteHostIcon(kind, size: 14, color: fg),
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Expandable panel header ("Pinned  3  ⌄"). Click to fold or unfold.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.count,
    required this.expanded,
    required this.onToggle,
    this.topPadding = 0,
  });

  final IconData icon;
  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(0, topPadding, 0, expanded ? 12 : 4),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: expanded ? 'Collapse' : 'Expand',
                  child: AnimatedRotation(
                    turns: expanded ? 0 : -0.25,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.expand_more_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "⋮" on each card: open, rename, show in the file manager, remove.
class _RepoCardMenu extends ConsumerWidget {
  const _RepoCardMenu({required this.repo, required this.onOpen});

  final TrackedRepo repo;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reveal = Platform.isMacOS
        ? 'Show in Finder'
        : Platform.isWindows
        ? 'Show in Explorer'
        : 'Show in Files';
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      padding: EdgeInsets.zero,
      onSelected: (action) async {
        switch (action) {
          case 'open':
            onOpen();
          case 'rename':
            await showRenameRepoDialog(context, ref, repo);
          case 'reveal':
            try {
              await ref
                  .read(systemLauncherProvider)
                  .revealInFileManager(repo.path);
            } catch (e) {
              final error = toGittyException(e);
              if (context.mounted) {
                showFriendlySnack(context, message: error.message, error: error);
              }
            }
          case 'remove':
            await confirmRemoveRepo(context, ref, repo);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'open',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.open_in_new_rounded),
            title: Text('Open'),
          ),
        ),
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_outlined),
            title: Text('Rename in Gitty…'),
          ),
        ),
        PopupMenuItem(
          value: 'reveal',
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.folder_open_outlined),
            title: Text(reveal),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'remove',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.playlist_remove_rounded),
            title: Text('Remove from Gitty'),
            subtitle: Text('Keeps your files'),
          ),
        ),
      ],
    );
  }
}

class _SnapshotDetails extends StatelessWidget {
  const _SnapshotDetails({required this.snapshot});

  final RepoSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = snapshot.status;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final commit = snapshot.lastCommit;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.call_split_rounded,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                status.branch ?? 'detached HEAD',
                style: theme.textTheme.labelLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              status.isClean ? Icons.done_all_rounded : Icons.edit_note_rounded,
              size: 16,
              color: status.isClean ? Colors.green : theme.colorScheme.tertiary,
            ),
            const SizedBox(width: 4),
            Text(
              status.isClean
                  ? 'Clean'
                  : plural(status.changes.length, 'change'),
              style: theme.textTheme.labelLarge,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          commit == null
              ? 'No commits yet'
              : '“${commit.subject}” · ${timeAgo(commit.date)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: muted,
        ),
      ],
    );
  }
}

/// Card footer for a connected folder that doesn't use Git yet.
class _NotInitializedDetails extends StatelessWidget {
  const _NotInitializedDetails({required this.onSetUp});

  final VoidCallback onSetUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.eco_outlined, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Not using Git yet',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge,
          ),
        ),
        TextButton(onPressed: onSetUp, child: const Text('Init Git')),
      ],
    );
  }
}

class _CardError extends ConsumerWidget {
  const _CardError({required this.error, required this.repo});

  final Object error;
  final TrackedRepo repo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final e = toGittyException(error);
    return Row(
      children: [
        Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            e.message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
        TextButton(
          onPressed: () =>
              ref.read(trackedReposProvider.notifier).remove(repo.path),
          child: const Text('Remove'),
        ),
      ],
    );
  }
}

/// Which hosting service each tracked repository uses (path → kind; `null`
/// kind = no remote). Repos still loading are left out. Compared by value,
/// so the dashboard only rebuilds when a host really changes — not every
/// time one repo's lookup reloads.
class _HostIndex {
  const _HostIndex(this.kinds);

  final Map<String, RemoteHostKind?> kinds;

  @override
  bool operator ==(Object other) =>
      other is _HostIndex && mapEquals(other.kinds, kinds);

  @override
  int get hashCode => Object.hashAllUnordered(
    kinds.entries.map((e) => Object.hash(e.key, e.value)),
  );
}

final _hostIndexProvider = Provider.autoDispose<_HostIndex>((ref) {
  final kinds = <String, RemoteHostKind?>{};
  for (final repo in ref.watch(trackedReposProvider)) {
    final host = ref.watch(remoteHostProvider(repo.path));
    if (host.hasValue) kinds[repo.path] = host.value?.kind;
  }
  return _HostIndex(kinds);
});

/// A dashboard card that can be dragged by its handle (⠿) onto another
/// card in the same section to take its place. The order is saved.
class _DraggableRepoCard extends ConsumerStatefulWidget {
  const _DraggableRepoCard({
    super.key,
    required this.repo,
    required this.canDrag,
    required this.onOpen,
  });

  final TrackedRepo repo;
  final bool canDrag;
  final VoidCallback onOpen;

  @override
  ConsumerState<_DraggableRepoCard> createState() => _DraggableRepoCardState();
}

class _DraggableRepoCardState extends ConsumerState<_DraggableRepoCard> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);

        Widget handle({required bool active}) => Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Icon(
            Icons.drag_indicator_rounded,
            size: 18,
            color: scheme.onSurfaceVariant.withValues(
              alpha: active ? 0.9 : 0.55,
            ),
          ),
        );

        final dragHandle = !widget.canDrag
            ? null
            : Draggable<TrackedRepo>(
                data: repo,
                // Keep the floating copy exactly where the card was under
                // the pointer.
                dragAnchorStrategy: (draggable, handleContext, position) {
                  final handleBox =
                      handleContext.findRenderObject() as RenderBox;
                  final cardBox = this.context.findRenderObject() as RenderBox;
                  final handleInCard =
                      handleBox.localToGlobal(Offset.zero) -
                      cardBox.localToGlobal(Offset.zero);
                  return handleBox.globalToLocal(position) + handleInCard;
                },
                onDragStarted: () => setState(() => _dragging = true),
                onDragEnd: (_) {
                  if (mounted) setState(() => _dragging = false);
                },
                feedback: SizedBox.fromSize(
                  size: size,
                  child: Material(
                    elevation: 10,
                    color: Colors.transparent,
                    shadowColor: scheme.shadow,
                    borderRadius: BorderRadius.circular(16),
                    child: Opacity(
                      opacity: 0.95,
                      child: RepoCard(
                        repo: repo,
                        onOpen: () {},
                        dragHandle: handle(active: true),
                      ),
                    ),
                  ),
                ),
                child: Tooltip(
                  message: 'Drag to reorder',
                  waitDuration: const Duration(milliseconds: 600),
                  child: MouseRegion(
                    cursor: _dragging
                        ? SystemMouseCursors.grabbing
                        : SystemMouseCursors.grab,
                    // Swallow plain clicks so they don't open the repo.
                    child: GestureDetector(
                      onTap: () {},
                      child: handle(active: _dragging),
                    ),
                  ),
                ),
              );

        return DragTarget<TrackedRepo>(
          // Pinned and other repositories are reordered separately.
          onWillAcceptWithDetails: (d) =>
              d.data.path != repo.path && d.data.pinned == repo.pinned,
          onAcceptWithDetails: (d) => ref
              .read(trackedReposProvider.notifier)
              .reorder(d.data.path, repo.path),
          builder: (context, candidates, _) {
            final hovered = candidates.isNotEmpty;
            return AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: _dragging ? 0.35 : 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepoCard(
                    repo: repo,
                    onOpen: widget.onOpen,
                    dragHandle: dragHandle,
                  ),
                  // "Drop here" outline.
                  IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: hovered
                            ? scheme.primary.withValues(alpha: 0.06)
                            : Colors.transparent,
                        border: Border.all(
                          color: hovered ? scheme.primary : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
