import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/errors/gitty_exception.dart';
import '../../../core/utils/time_ago.dart';
import '../../../services/git/git_models.dart';
import '../../../services/service_providers.dart';

/// Explains a git lock file in plain words, checks whether something is
/// still using it, and — only if it's a leftover — offers to remove it.
/// Returns true when the lock is gone (removed, or freed on its own), so the
/// caller can try the action again.
Future<bool> showRepoLockDialog(
  BuildContext context, {
  required String repoPath,
  required String lockPath,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _RepoLockDialog(repoPath: repoPath, lockPath: lockPath),
  );
  return result ?? false;
}

class _RepoLockDialog extends ConsumerStatefulWidget {
  const _RepoLockDialog({required this.repoPath, required this.lockPath});

  final String repoPath;
  final String lockPath;

  @override
  ConsumerState<_RepoLockDialog> createState() => _RepoLockDialogState();
}

class _RepoLockDialogState extends ConsumerState<_RepoLockDialog> {
  GitLockInfo? _info;
  bool _checking = true;
  bool _removing = false;
  GittyException? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final info = await ref
        .read(gitServiceProvider)
        .inspectLock(widget.repoPath, widget.lockPath);
    if (!mounted) return;
    setState(() {
      _info = info;
      _checking = false;
    });
  }

  Future<void> _remove() async {
    setState(() {
      _removing = true;
      _error = null;
    });
    try {
      await ref.read(gitServiceProvider).removeLock(widget.lockPath);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _removing = false;
          _error = toGittyException(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final info = _info;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final lockName = p.basename(widget.lockPath);

    final (IconData icon, Color color, String headline, String body) =
        _checking || info == null
        ? (
            Icons.hourglass_top_rounded,
            scheme.onSurfaceVariant,
            'Checking what’s holding it…',
            '',
          )
        : !info.exists
        ? (
            Icons.check_circle_outline,
            Colors.green,
            'It’s free again',
            'The other program finished and removed the lock. You can go ahead.',
          )
        : info.inUse == true
        ? (
            Icons.pending_outlined,
            scheme.tertiary,
            'Something is still using it',
            'A Git command is running in this repository right now — maybe your '
                'editor (a commit message waiting to be saved?), your IDE, or a '
                'terminal. Let it finish or close it, then check again.',
          )
        : info.isLeftover
        ? (
            Icons.cleaning_services_outlined,
            scheme.primary,
            'It’s a leftover — safe to remove',
            'Nothing is using it. A Git command stopped halfway'
                '${info.modified == null ? '' : ' ${timeAgo(info.modified!)}'} '
                'and never cleaned up. Removing the lock doesn’t touch your '
                'files, changes or history.',
          )
        : (
            Icons.help_outline_rounded,
            scheme.onSurfaceVariant,
            'Gitty can’t tell if it’s still in use',
            'If no editor, IDE or terminal is running Git in this repository, '
                'it’s a leftover and safe to remove.',
          );

    return AlertDialog(
      title: const Text('Git is locked'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'While Git changes things it keeps a small “$lockName” file so two '
              'programs don’t change the same thing at once. It’s still there, '
              'so Git waited.',
              style: muted,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _checking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(icon, color: color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(headline, style: theme.textTheme.titleSmall),
                        if (body.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(body, style: theme.textTheme.bodySmall),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(
              widget.lockPath,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                [_error!.message, if (_error!.hint != null) _error!.hint!].join(' '),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _removing ? null : () => Navigator.pop(context, false),
          child: const Text('Close'),
        ),
        if (info != null && info.exists && !info.isLeftover)
          TextButton(
            onPressed: _checking || _removing ? null : _check,
            child: const Text('Check again'),
          ),
        if (info != null && !info.exists)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Try again'),
          )
        else if (info != null && info.isLeftover)
          FilledButton.icon(
            onPressed: _removing ? null : _remove,
            icon: const Icon(Icons.cleaning_services_outlined, size: 18),
            label: const Text('Remove leftover lock & try again'),
          )
        else if (info != null && info.inUse == null)
          // Can't check on this system: let the user decide, clearly worded.
          TextButton(
            onPressed: _removing ? null : _remove,
            child: const Text('Nothing else is running — remove it'),
          ),
      ],
    );
  }
}
