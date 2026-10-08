import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../core/utils/time_ago.dart';
import '../../../services/git/git_models.dart';

/// Asks before reverting. Explains, per file, what will happen ("goes back
/// to the last commit" / "is new, so it's removed") and whether Gitty can
/// keep an undo backup. Returns true when the user confirms.
Future<bool> confirmRevert(
  BuildContext context, {
  required List<FileChange> changes,
  required bool all,
  required bool canUndo,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) =>
        _RevertDialog(changes: changes, all: all, canUndo: canUndo),
  );
  return result ?? false;
}

class _RevertDialog extends StatelessWidget {
  const _RevertDialog({
    required this.changes,
    required this.all,
    required this.canUndo,
  });

  final List<FileChange> changes;
  final bool all;
  final bool canUndo;

  static bool _isNew(FileChange c) =>
      c.kind == FileChangeKind.untracked || c.kind == FileChangeKind.added;

  static String _whatHappens(FileChange c) => switch (c.kind) {
    FileChangeKind.untracked ||
    FileChangeKind.added => 'is new, so it will be removed',
    FileChangeKind.deleted => 'comes back as it was in the last commit',
    FileChangeKind.renamed => 'gets its old name and content back',
    FileChangeKind.conflicted => 'drops the conflict and goes back to your last commit',
    _ => 'goes back to how it was in the last commit',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final newFiles = changes.where(_isNew).length;
    final changed = changes.length - newFiles;
    final single = changes.length == 1 ? changes.first : null;

    final summary = single != null
        ? '“${p.basename(single.path)}” ${_whatHappens(single)}.'
        : [
            if (changed > 0)
              '${plural(changed, 'changed file')} go${changed == 1 ? 'es' : ''} back to your last commit',
            if (newFiles > 0)
              '${plural(newFiles, 'new file')} ${newFiles == 1 ? 'is' : 'are'} removed',
          ].join(', and ').replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase()) +
              '.';

    return AlertDialog(
      icon: Icon(Icons.undo_rounded, color: scheme.error),
      title: Text(
        all
            ? 'Revert all changes?'
            : single != null
            ? 'Revert “${p.basename(single.path)}”?'
            : 'Revert ${plural(changes.length, 'file')}?',
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(summary, style: theme.textTheme.bodyMedium),
            if (single == null) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in changes)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(
                              _isNew(c)
                                  ? Icons.remove_circle_outline
                                  : Icons.history_rounded,
                              size: 16,
                              color: _isNew(c)
                                  ? scheme.error
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                c.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: canUndo
                    ? scheme.secondaryContainer.withValues(alpha: 0.6)
                    : scheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    canUndo ? Icons.inventory_2_outlined : Icons.warning_amber_rounded,
                    size: 20,
                    color: canUndo
                        ? scheme.onSecondaryContainer
                        : scheme.onErrorContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      canUndo
                          ? 'Gitty tucks a backup away first, so you can press '
                                '“Undo” right after if you change your mind.'
                          : 'This can’t be undone — there’s no commit yet to keep '
                                'a backup against.',
                      style: TextStyle(
                        color: canUndo
                            ? scheme.onSecondaryContainer
                            : scheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.undo_rounded, size: 18),
          label: Text(all ? 'Revert all' : 'Revert'),
        ),
      ],
    );
  }
}
