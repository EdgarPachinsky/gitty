import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../services/git/git_models.dart';
import '../repo_actions_controller.dart';

/// Lists staged and unstaged changes with staging controls.
class ChangesPanel extends StatelessWidget {
  const ChangesPanel({
    super.key,
    required this.status,
    required this.selected,
    required this.busy,
    required this.onToggle,
    required this.onStageAll,
    required this.onStageSelected,
    required this.onStageOne,
    required this.onUnstageOne,
    required this.onUnstageAll,
    required this.onRevertAll,
    required this.onRevertOne,
    this.summary,
    this.onResolveConflicts,
  });

  final RepoStatus status;
  final Set<String> selected;
  final GitAction? busy;
  final void Function(String path, bool selected) onToggle;
  final VoidCallback onStageAll;
  final VoidCallback onStageSelected;
  final ValueChanged<FileChange> onStageOne;
  final ValueChanged<FileChange> onUnstageOne;
  final VoidCallback onUnstageAll;

  /// Revert everything / one file (the caller asks for confirmation).
  final VoidCallback onRevertAll;
  final ValueChanged<FileChange> onRevertOne;

  /// Note about the changes, shown under the title (it hides itself when
  /// there's nothing to describe).
  final Widget? summary;

  /// Opens the conflict resolver.
  final VoidCallback? onResolveConflicts;

  /// Rendering thousands of rows helps nobody; show the first chunk.
  static const _maxRows = 300;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final staged = status.changes.where((c) => c.staged).toList();
    final unstaged = status.changes.where((c) => c.unstaged).toList();
    final idle = busy == null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('Changes', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (busy == GitAction.stage ||
                    busy == GitAction.unstage ||
                    busy == GitAction.revert)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (selected.isNotEmpty)
                  FilledButton.tonal(
                    onPressed: idle ? onStageSelected : null,
                    child: Text('Stage selected (${selected.length})'),
                  )
                else if (unstaged.isNotEmpty)
                  FilledButton.tonalIcon(
                    onPressed: idle ? onStageAll : null,
                    icon: const Icon(
                      Icons.playlist_add_check_rounded,
                      size: 18,
                    ),
                    label: const Text('Stage all'),
                  ),
                if (!status.isClean) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Throw away all changes and go back to your last commit',
                    child: OutlinedButton.icon(
                      onPressed: idle ? onRevertAll : null,
                      icon: const Icon(Icons.undo_rounded, size: 18),
                      label: const Text('Revert all'),
                    ),
                  ),
                ],
              ],
            ),
            if (summary != null) summary!,
            if (status.conflictCount > 0) ...[
              const SizedBox(height: 12),
              _Notice(
                icon: Icons.warning_amber_rounded,
                text:
                    '${status.conflictCount == 1 ? '1 file has' : '${status.conflictCount} files have'} '
                    'clashing changes. Pick what to keep, side by side.',
                color: theme.colorScheme.errorContainer,
                onColor: theme.colorScheme.onErrorContainer,
                action: onResolveConflicts == null
                    ? null
                    : FilledButton.icon(
                        onPressed: onResolveConflicts,
                        icon: const Icon(Icons.call_merge_rounded, size: 18),
                        label: const Text('Resolve conflicts'),
                      ),
              ),
            ],
            const SizedBox(height: 12),
            if (status.isClean)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.spa_outlined,
                        size: 36,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'All clean — nothing to commit.',
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        'Edit some files and they’ll show up here.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              _LimitedHeight(
                // About half the window, so a big change list scrolls inside
                // the card instead of pushing everything else far down.
                maxHeight: (MediaQuery.sizeOf(context).height * 0.5)
                    .clamp(280.0, 640.0)
                    .toDouble(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
              if (staged.isNotEmpty) ...[
                _SectionHeader(
                  title: 'Ready to commit',
                  count: staged.length,
                  action: TextButton(
                    onPressed: idle ? onUnstageAll : null,
                    child: const Text('Unstage all'),
                  ),
                ),
                for (final c in staged.take(_maxRows))
                  _ChangeRow(
                    change: c,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RevertButton(
                          onPressed: idle ? () => onRevertOne(c) : null,
                        ),
                        IconButton(
                          tooltip: 'Unstage',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            size: 18,
                          ),
                          onPressed: idle ? () => onUnstageOne(c) : null,
                        ),
                      ],
                    ),
                  ),
                if (staged.length > _maxRows)
                  _MoreRow(count: staged.length - _maxRows),
                const SizedBox(height: 12),
              ],
              if (unstaged.isNotEmpty) ...[
                _SectionHeader(title: 'Not staged yet', count: unstaged.length),
                for (final c in unstaged.take(_maxRows))
                  _ChangeRow(
                    change: c,
                    selected: selected.contains(c.path),
                    onSelected: (v) => onToggle(c.path, v),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RevertButton(
                          onPressed: idle ? () => onRevertOne(c) : null,
                        ),
                        IconButton(
                          tooltip: 'Stage',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.add_circle_outline, size: 18),
                          onPressed: idle ? () => onStageOne(c) : null,
                        ),
                      ],
                    ),
                  ),
                if (unstaged.length > _maxRows)
                  _MoreRow(count: unstaged.length - _maxRows),
              ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Small "revert this file" button (asks before doing anything).
class _RevertButton extends StatelessWidget {
  const _RevertButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Revert…',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.undo_rounded, size: 18),
      onPressed: onPressed,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count, this.action});

  final String title;
  final int count;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.8),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    required this.change,
    required this.trailing,
    this.selected,
    this.onSelected,
  });

  final FileChange change;
  final Widget trailing;
  final bool? selected;
  final ValueChanged<bool>? onSelected;

  static (String, Color) badgeFor(FileChangeKind kind) => switch (kind) {
    FileChangeKind.modified => ('M', const Color(0xFFD9901A)),
    FileChangeKind.added => ('A', const Color(0xFF2E9E6A)),
    FileChangeKind.untracked => ('U', const Color(0xFF2E9E6A)),
    FileChangeKind.deleted => ('D', const Color(0xFFE0574F)),
    FileChangeKind.renamed => ('R', const Color(0xFF3B7BE0)),
    FileChangeKind.copied => ('C', const Color(0xFF3B7BE0)),
    FileChangeKind.typeChanged => ('T', const Color(0xFF8A8FA3)),
    FileChangeKind.conflicted => ('!', const Color(0xFFE0574F)),
  };

  static String describe(FileChangeKind kind) => switch (kind) {
    FileChangeKind.modified => 'Modified',
    FileChangeKind.added => 'Added',
    FileChangeKind.untracked => 'New file',
    FileChangeKind.deleted => 'Deleted',
    FileChangeKind.renamed => 'Renamed',
    FileChangeKind.copied => 'Copied',
    FileChangeKind.typeChanged => 'Type changed',
    FileChangeKind.conflicted => 'Conflict',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (letter, color) = badgeFor(change.kind);
    final dir = p.dirname(change.path);
    final name = p.basename(change.path);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onSelected == null
          ? null
          : () => onSelected!(!(selected ?? false)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            if (onSelected != null)
              Checkbox(
                value: selected ?? false,
                visualDensity: VisualDensity.compact,
                onChanged: (v) => onSelected!(v ?? false),
              )
            else
              const SizedBox(width: 12),
            Tooltip(
              message: describe(change.kind),
              child: Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  letter,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: name,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    if (dir != '.')
                      TextSpan(
                        text: '  $dir',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    if (change.originalPath != null)
                      TextSpan(
                        text: '  ← ${change.originalPath}',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Text(
        '…and $count more',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    required this.color,
    required this.onColor,
    this.action,
  });

  final IconData icon;
  final String text;
  final Color color;
  final Color onColor;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: onColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: onColor)),
          ),
          if (action != null) ...[const SizedBox(width: 10), action!],
        ],
      ),
    );
  }
}

/// Lets [child] grow up to [maxHeight], then scrolls (with a visible bar).
class _LimitedHeight extends StatefulWidget {
  const _LimitedHeight({required this.maxHeight, required this.child});

  final double maxHeight;
  final Widget child;

  @override
  State<_LimitedHeight> createState() => _LimitedHeightState();
}

class _LimitedHeightState extends State<_LimitedHeight> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.only(right: 12),
          child: widget.child,
        ),
      ),
    );
  }
}
