import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/time_ago.dart';
import '../../core/widgets/state_views.dart';
import '../../services/git/history.dart';
import '../../services/service_providers.dart';
import '../dashboard/tracked_repos_controller.dart';
import '../repository/repo_actions_controller.dart';
import 'undo.dart';

// --- Data ---------------------------------------------------------------------

/// Refreshes history whenever the repository moves (commit, switch, push,
/// pull, download…).
(String?, String?, int?, int?) _repoMoment(Ref ref, String path) => ref.watch(
  repoSnapshotProvider(path).select((s) {
    final st = s.value?.status;
    return (st?.headOid, st?.branch, st?.ahead, st?.behind);
  }),
);

final activityProvider = FutureProvider.autoDispose
    .family<List<ActivityEvent>, String>((ref, path) {
      _repoMoment(ref, path);
      return ref.watch(gitServiceProvider).activity(path);
    });

/// (repository path, how many commits to show)
final commitHistoryProvider = FutureProvider.autoDispose
    .family<List<HistoryCommit>, (String, int)>((ref, arg) {
      final (path, limit) = arg;
      _repoMoment(ref, path);
      final upstream = ref.watch(
        repoSnapshotProvider(path).select((s) => s.value?.status.upstream),
      );
      return ref
          .watch(gitServiceProvider)
          .commitHistory(path, upstream: upstream, limit: limit);
    });

/// (repository path, commit hash)
final commitDetailsProvider = FutureProvider.autoDispose
    .family<CommitDetails, (String, String)>(
      (ref, arg) =>
          ref.watch(gitServiceProvider).commitDetails(arg.$1, arg.$2),
    );

// --- Screen -------------------------------------------------------------------

/// "History": what happened in this repository, and its commits — in plain
/// words.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key, required this.repoPath, required this.title});

  final String repoPath;
  final String title;

  static Future<void> open(BuildContext context, String repoPath, String title) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => HistoryScreen(repoPath: repoPath, title: title),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('History'),
              Text(
                title,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () {
                ref.invalidate(activityProvider(repoPath));
                ref.invalidate(commitHistoryProvider);
              },
            ),
            const SizedBox(width: 8),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.timeline_rounded), text: 'What happened'),
              Tab(icon: Icon(Icons.commit), text: 'Commits'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ActivityTab(repoPath: repoPath),
            _CommitsTab(repoPath: repoPath),
          ],
        ),
      ),
    );
  }
}

// --- "What happened" -------------------------------------------------------------

class _ActivityTab extends ConsumerStatefulWidget {
  const _ActivityTab({required this.repoPath});

  final String repoPath;

  @override
  ConsumerState<_ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends ConsumerState<_ActivityTab> {
  ActivityGroup? _group; // null = everything

  /// Explains the undo, asks, then does it.
  Future<void> _runUndo(UndoPlan plan) async {
    final git = ref.read(gitServiceProvider);
    var chosen = plan;
    if (plan.ifOnline != null && plan.onlineHash != null) {
      if (await git.isOnline(widget.repoPath, plan.onlineHash!)) {
        chosen = plan.ifOnline!;
      }
    }
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          chosen.danger ? Icons.warning_amber_rounded : Icons.undo_rounded,
        ),
        title: Text(chosen.title),
        content: SizedBox(width: 460, child: Text(chosen.explanation)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: chosen.danger
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(chosen.label),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final outcome = await ref
        .read(repoActionsProvider(widget.repoPath).notifier)
        .undo((git) => chosen.run(git, widget.repoPath));
    ref.invalidate(activityProvider(widget.repoPath));
    if (mounted) {
      showFriendlySnack(context, message: outcome.message, error: outcome.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final activity = ref.watch(activityProvider(widget.repoPath));
    final status = ref.watch(
      repoSnapshotProvider(widget.repoPath).select((s) => s.value?.status),
    );
    final undoContext = UndoContext(
      headOid: status?.headOid,
      currentBranch: status?.branch,
      localBranches:
          ref.watch(branchesProvider(widget.repoPath)).value?.local.toSet() ??
          const {},
    );
    final busy = ref.watch(repoActionsProvider(widget.repoPath)) != null;

    return _Page(
      child: activity.when(
        loading: () => const LoadingView(message: 'Reading the history…'),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(activityProvider(widget.repoPath)),
        ),
        data: (all) {
          final events = _group == null
              ? all
              : all.where((e) => e.kind.group == _group).toList();
          final rows = <Object>[]; // String = day header, event = row
          String? day;
          for (final e in events) {
            final label = _dayLabel(e.time);
            if (label != day) rows.add(day = label);
            rows.add(e);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 12),
                child: Text(
                  'Everything done in this repository on this computer — in '
                  'Gitty, a terminal or your editor. Git remembers about the '
                  'last 90 days.',
                  style: muted,
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (group, label, icon) in [
                    (null, 'Everything', Icons.all_inclusive_rounded),
                    (ActivityGroup.commits, 'Commits', Icons.commit),
                    (ActivityGroup.branches, 'Branches', Icons.call_split_rounded),
                    (ActivityGroup.sync, 'Syncing', Icons.sync_rounded),
                  ])
                    ChoiceChip(
                      avatar: Icon(icon, size: 16),
                      label: Text(label),
                      selected: _group == group,
                      onSelected: (_) => setState(() => _group = group),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: rows.isEmpty
                    ? EmptyState(
                        icon: Icons.history_toggle_off_rounded,
                        title: _group == null
                            ? 'Nothing recorded yet'
                            : 'Nothing of this kind yet',
                        message:
                            'Commits, branch switches, pulls and pushes will '
                            'show up here as they happen.',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final row = rows[i];
                          if (row is String) return _DayHeader(label: row);
                          final event = row as ActivityEvent;
                          final plan = undoPlanFor(event, undoContext);
                          return _EventTile(
                            event: event,
                            undo: plan,
                            onUndo: plan == null || busy
                                ? null
                                : () => _runUndo(plan),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event, this.undo, this.onUndo});

  final ActivityEvent event;

  /// How this can be undone (null = it can't, right now).
  final UndoPlan? undo;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (bg, fg) = switch (event.kind.group) {
      ActivityGroup.commits => (scheme.primaryContainer, scheme.onPrimaryContainer),
      ActivityGroup.branches => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      ActivityGroup.sync => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
    };
    final isCommitMessage = switch (event.kind) {
      ActivityKind.commit ||
      ActivityKind.firstCommit ||
      ActivityKind.amend ||
      ActivityKind.cherryPick ||
      ActivityKind.revert => true,
      _ => false,
    };
    final detail = event.detail;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: Icon(_iconFor(event.kind), size: 18, color: fg),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(
                  event.title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (detail != null && detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      isCommitMessage ? '“$detail”' : detail,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontStyle: isCommitMessage ? FontStyle.italic : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const SizedBox(height: 3),
              Tooltip(
                message: timeAgo(event.time),
                child: Text(_clock(event.time), style: theme.textTheme.labelMedium),
              ),
              if (event.shortHash != null && isCommitMessage)
                _HashChip(hash: event.hash!, short: event.shortHash!),
              if (undo != null)
                Tooltip(
                  message: undo!.title,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: undo!.danger ? scheme.error : null,
                    ),
                    onPressed: onUndo,
                    icon: const Icon(Icons.undo_rounded, size: 16),
                    label: Text(undo!.label),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(ActivityKind kind) => switch (kind) {
    ActivityKind.commit => Icons.check_circle_outline_rounded,
    ActivityKind.firstCommit => Icons.flag_outlined,
    ActivityKind.amend => Icons.edit_outlined,
    ActivityKind.cherryPick => Icons.content_copy_rounded,
    ActivityKind.revert => Icons.undo_rounded,
    ActivityKind.switchBranch => Icons.alt_route_rounded,
    ActivityKind.detach => Icons.history_rounded,
    ActivityKind.createBranch => Icons.add_road_rounded,
    ActivityKind.renameBranch => Icons.drive_file_rename_outline_rounded,
    ActivityKind.merge => Icons.merge_rounded,
    ActivityKind.rebase => Icons.low_priority_rounded,
    ActivityKind.reset => Icons.restore_rounded,
    ActivityKind.pull => Icons.download_rounded,
    ActivityKind.push => Icons.upload_rounded,
    ActivityKind.publish => Icons.cloud_upload_outlined,
    ActivityKind.fetch => Icons.cloud_sync_outlined,
    ActivityKind.clone => Icons.cloud_download_outlined,
    ActivityKind.other => Icons.circle_outlined,
  };
}

// --- Commits -------------------------------------------------------------------

class _CommitsTab extends ConsumerStatefulWidget {
  const _CommitsTab({required this.repoPath});

  final String repoPath;

  @override
  ConsumerState<_CommitsTab> createState() => _CommitsTabState();
}

class _CommitsTabState extends ConsumerState<_CommitsTab> {
  static const _page = 150;
  int _limit = _page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final status = ref.watch(
      repoSnapshotProvider(widget.repoPath).select((s) => s.value?.status),
    );
    final history = ref.watch(commitHistoryProvider((widget.repoPath, _limit)));

    return _Page(
      child: history.when(
        // Keep showing the list while "Load more" fetches.
        skipLoadingOnReload: true,
        loading: () => const LoadingView(message: 'Reading commits…'),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(commitHistoryProvider),
        ),
        data: (commits) {
          if (commits.isEmpty) {
            return const EmptyState(
              icon: Icons.commit,
              title: 'No commits yet',
              message: 'Make your first commit and it will appear here.',
            );
          }
          final incoming = commits.where((c) => c.onlineOnly).toList();
          final yours = commits.where((c) => !c.onlineOnly).toList();
          final upstream = status?.upstream;
          return ListView(
            padding: const EdgeInsets.only(top: 16, bottom: 24),
            children: [
              Text(
                upstream == null
                    ? 'The commits on ${status?.branch ?? 'this branch'}, '
                          'newest first.'
                    : 'The commits on ${status?.branch ?? 'this branch'}, '
                          'newest first — including ones on $upstream you '
                          'haven’t downloaded yet.',
                style: muted,
              ),
              const SizedBox(height: 12),
              if (incoming.isNotEmpty) ...[
                _SectionTitle(
                  icon: Icons.cloud_download_outlined,
                  text: 'Online, not in your copy yet (${incoming.length})',
                  note: 'Use Pull to bring them in.',
                ),
                for (final c in incoming)
                  _CommitTile(repoPath: widget.repoPath, commit: c),
                const SizedBox(height: 16),
                _SectionTitle(
                  icon: Icons.laptop_mac_rounded,
                  text: 'In your copy',
                ),
              ],
              for (final c in yours)
                _CommitTile(repoPath: widget.repoPath, commit: c),
              if (commits.length >= _limit)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Center(
                    child: OutlinedButton.icon(
                      onPressed: () => setState(() => _limit += _page),
                      icon: const Icon(Icons.expand_more_rounded),
                      label: const Text('Show older commits'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CommitTile extends StatelessWidget {
  const _CommitTile({required this.repoPath, required this.commit});

  final String repoPath;
  final HistoryCommit commit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = commit;
    final avatarColors = [
      (scheme.primaryContainer, scheme.onPrimaryContainer),
      (scheme.secondaryContainer, scheme.onSecondaryContainer),
      (scheme.tertiaryContainer, scheme.onTertiaryContainer),
    ];
    final (bg, fg) =
        avatarColors[c.email.codeUnits.fold(0, (a, b) => a + b) %
            avatarColors.length];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: c.onlineOnly ? scheme.surfaceContainerHighest : null,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: CircleAvatar(
            radius: 17,
            backgroundColor: bg,
            child: Text(
              _initials(c.author),
              style: theme.textTheme.labelMedium?.copyWith(color: fg),
            ),
          ),
          title: Text(
            c.subject,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${c.author} · ${timeAgo(c.date)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (c.notPushed)
                  const _Badge(
                    icon: Icons.upload_rounded,
                    text: 'Not uploaded yet',
                  ),
                if (c.onlineOnly)
                  const _Badge(
                    icon: Icons.cloud_outlined,
                    text: 'Online only',
                  ),
                if (c.isMerge)
                  const _Badge(icon: Icons.merge_rounded, text: 'Merge'),
                for (final r in c.refs) _RefChip(label: r),
              ],
            ),
          ),
          children: [_CommitDetailsView(repoPath: repoPath, commit: c)],
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    if (parts.isEmpty) return '?';
    final letters = parts.take(2).map((s) => s.characters.first.toUpperCase());
    return letters.join();
  }
}

class _CommitDetailsView extends ConsumerWidget {
  const _CommitDetailsView({required this.repoPath, required this.commit});

  final String repoPath;
  final HistoryCommit commit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final details = ref.watch(commitDetailsProvider((repoPath, commit.hash)));
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${_fullDate(commit.date)} · ${commit.email}',
                style: muted,
              ),
            ),
            _HashChip(hash: commit.hash, short: commit.shortHash),
          ],
        ),
        const SizedBox(height: 8),
        details.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(8),
            child: LinearProgressIndicator(minHeight: 2),
          ),
          error: (e, _) => ErrorView(error: e, compact: true),
          data: (d) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (d.body.isNotEmpty) ...[
                SelectableText(d.body, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 10),
              ],
              if (d.files.isEmpty)
                Text(
                  commit.isMerge
                      ? 'A merge commit — it joins two histories and doesn’t '
                            'change files by itself.'
                      : 'No file changes.',
                  style: muted,
                )
              else ...[
                Text(
                  '${plural(d.files.length, 'file')} changed',
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                for (final f in d.files)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Icon(
                          Icons.description_outlined,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            f.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        if (f.added == null)
                          Text('binary', style: muted)
                        else ...[
                          Text(
                            '+${f.added}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: Colors.green.shade600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '−${f.deleted}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// --- Small pieces -----------------------------------------------------------------

/// Centers content at a readable width.
class _Page extends StatelessWidget {
  const _Page({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 860),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: child,
      ),
    ),
  );
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.text, this.note});

  final IconData icon;
  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(text, style: theme.textTheme.titleSmall),
          if (note != null) ...[
            const SizedBox(width: 8),
            Text(
              note!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

/// "main", "origin/main" (online copy) or "tag: v1".
class _RefChip extends StatelessWidget {
  const _RefChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isTag = label.startsWith('tag: ');
    final isRemote = !isTag && label.contains('/') && !label.startsWith('refs/')
        ? label.split('/').first == 'origin' || label.split('/').first == 'upstream'
        : false;
    final text = isTag ? label.substring(5) : label;
    return Tooltip(
      message: isTag
          ? 'Tag'
          : isRemote
          ? 'Online copy of ${label.substring(label.indexOf('/') + 1)}'
          : 'Branch on this computer',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isTag
                  ? Icons.sell_outlined
                  : isRemote
                  ? Icons.cloud_outlined
                  : Icons.call_split_rounded,
              size: 12,
              color: scheme.primary,
            ),
            const SizedBox(width: 4),
            Text(text, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

class _HashChip extends StatefulWidget {
  const _HashChip({required this.hash, required this.short});

  final String hash;
  final String short;

  @override
  State<_HashChip> createState() => _HashChipState();
}

class _HashChipState extends State<_HashChip> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: _copied ? 'Copied' : 'Copy commit id',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: widget.hash));
          if (!mounted) return;
          setState(() => _copied = true);
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          if (mounted) setState(() => _copied = false);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.short,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 3),
              Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                size: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Dates (no extra packages) -----------------------------------------------------

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _dayLabel(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  final base = '${_weekdays[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]}';
  return t.year == now.year ? base : '$base ${t.year}';
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _fullDate(DateTime t) =>
    '${t.day} ${_months[t.month - 1]} ${t.year}, ${_clock(t)}';
