import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../dashboard/repo_widgets.dart';
import '../dashboard/tracked_repos_controller.dart';
import 'open_tabs.dart';

/// Browser-style tabs above the content: "Repositories" first, then every
/// open repository. Click to switch, × or middle-click to close, drag to
/// reorder, right-click for more.
class RepoTabStrip extends ConsumerWidget {
  const RepoTabStrip({super.key, required this.paths, required this.active});

  final List<String> paths;
  final String? active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final tabs = ref.read(openTabsProvider.notifier);
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HomeTab(selected: active == null, onTap: () => tabs.activate(null)),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < paths.length; i++)
                  _DraggableTab(
                    key: ValueKey(paths[i]),
                    path: paths[i],
                    index: i,
                    selected: paths[i] == active,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _TabShell(
      selected: selected,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(
              Icons.grid_view_rounded,
              size: 16,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text('Repositories', style: theme.textTheme.labelLarge),
          ],
        ),
      ),
    );
  }
}

/// A tab that can be dragged onto another tab to take its place.
class _DraggableTab extends ConsumerWidget {
  const _DraggableTab({
    super.key,
    required this.path,
    required this.index,
    required this.selected,
  });

  final String path;
  final int index;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final tab = _RepoTab(path: path, selected: selected);
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != path,
      onAcceptWithDetails: (d) =>
          ref.read(openTabsProvider.notifier).move(d.data, index),
      builder: (context, candidates, _) => Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: candidates.isNotEmpty ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Draggable<String>(
          data: path,
          axis: Axis.horizontal,
          feedback: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 40,
              child: _RepoTab(path: path, selected: true),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.4, child: tab),
          child: tab,
        ),
      ),
    );
  }
}

class _RepoTab extends ConsumerWidget {
  const _RepoTab({required this.path, required this.selected});

  final String path;
  final bool selected;

  Future<void> _menu(BuildContext context, WidgetRef ref, Offset at) async {
    final tabs = ref.read(openTabsProvider.notifier);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(value: 'close', child: Text('Close tab')),
        PopupMenuItem(value: 'others', child: Text('Close other tabs')),
        PopupMenuItem(value: 'all', child: Text('Close all tabs')),
      ],
    );
    switch (choice) {
      case 'close':
        tabs.close(path);
      case 'others':
        tabs.closeOthers(path);
      case 'all':
        tabs.closeAll();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tabs = ref.read(openTabsProvider.notifier);
    final title =
        ref
            .watch(trackedReposProvider)
            .where((r) => r.path == path)
            .firstOrNull
            ?.title ??
        p.basename(path);
    // Small dot: uncommitted changes (red when something clashes).
    final (changes, conflicts) = ref.watch(
      repoSnapshotProvider(path).select(
        (s) => (
          s.value?.status.changes.length ?? 0,
          s.value?.status.conflictCount ?? 0,
        ),
      ),
    );

    return Listener(
      onPointerDown: (e) {
        if (e.buttons == kMiddleMouseButton) tabs.close(path);
      },
      child: GestureDetector(
        onSecondaryTapUp: (d) => _menu(context, ref, d.globalPosition),
        child: _TabShell(
          selected: selected,
          onTap: () => tabs.activate(path),
          tooltip: path,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 120, maxWidth: 240),
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RemoteHostLogo(repoPath: path, size: 14),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (changes > 0) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: conflicts > 0
                          ? 'Has clashing changes'
                          : '$changes uncommitted change${changes == 1 ? '' : 's'}',
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: conflicts > 0 ? scheme.error : scheme.tertiary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: 'Close tab',
                    visualDensity: VisualDensity.compact,
                    iconSize: 14,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 26,
                      height: 26,
                    ),
                    onPressed: () => tabs.close(path),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared look: the selected tab is lifted, with an accent line on top.
class _TabShell extends StatelessWidget {
  const _TabShell({
    required this.selected,
    required this.onTap,
    required this.child,
    this.tooltip,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tile = Material(
      color: selected ? scheme.surface : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 2,
              ),
              right: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
    return tooltip == null
        ? tile
        : Tooltip(
            message: tooltip!,
            waitDuration: const Duration(milliseconds: 800),
            child: tile,
          );
  }
}
