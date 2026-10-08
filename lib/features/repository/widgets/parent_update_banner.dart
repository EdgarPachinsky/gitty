import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../services/git/git_models.dart';
import '../../sync/live_sync.dart';

/// "main — the branch yours grew from — has 3 new changes (from Ana)."
///
/// Appears when the parent branch (usually on origin, so it reflects
/// teammates' pushes) has moved ahead of your branch, with one click to
/// bring those changes in. Styled like [SyncBanner].
class ParentUpdateBanner extends ConsumerStatefulWidget {
  const ParentUpdateBanner({
    super.key,
    required this.repoPath,
    required this.busy,
    required this.onBringIn,
  });

  final String repoPath;
  final bool busy;
  final ValueChanged<ParentSync> onBringIn;

  @override
  ConsumerState<ParentUpdateBanner> createState() => _ParentUpdateBannerState();
}

class _ParentUpdateBannerState extends ConsumerState<ParentUpdateBanner> {
  /// "Not now" per repository, until the parent moves again.
  static final _dismissedTip = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(parentSyncProvider(widget.repoPath)).value;
    if (sync == null ||
        sync.behind == 0 ||
        _dismissedTip[widget.repoPath] == sync.parentTip) {
      return const SizedBox.shrink();
    }

    final notice = ref
        .watch(remoteUpdatesProvider)
        .where(
          (n) =>
              n.repoPath == widget.repoPath &&
              n.update.remoteRef == sync.parentRef,
        )
        .lastOrNull;

    final theme = Theme.of(context);
    final colors = StatusColors.forSync(
      SyncState.behind,
      theme.colorScheme,
    );
    final changes = sync.behind == 1
        ? '1 new change'
        : '${sync.behind} new changes';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(AppTheme.radius),
        ),
        child: Row(
          children: [
            Icon(Icons.park_outlined, color: colors.foreground),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '“${sync.parent}” has $changes your branch doesn’t have yet',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (notice != null) '${notice.who} just pushed them.',
                      '“${sync.branch}” grew from “${sync.parent}”. Bringing these '
                          'in now keeps you up to date and keeps conflicts small.',
                    ].join(' '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.foreground,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: widget.busy ? null : () => widget.onBringIn(sync),
                  child: const Text('Bring them in'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() {
                    final tip = sync.parentTip;
                    if (tip != null) _dismissedTip[widget.repoPath] = tip;
                  }),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
