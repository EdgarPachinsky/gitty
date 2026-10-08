import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/time_ago.dart';
import '../../../services/git/git_models.dart';

/// Gentle, non-blocking hint about how the branch relates to its remote,
/// with the most sensible next step one click away.
class SyncBanner extends StatelessWidget {
  const SyncBanner({
    super.key,
    required this.status,
    required this.busy,
    required this.onPull,
    required this.onChoosePull,
    required this.onPush,
    required this.onSwitchBranch,
    this.remoteBranch,
    this.onLink,
  });

  /// A same-named branch on the remote (e.g. `origin/main`) when this branch
  /// has no upstream link yet.
  final String? remoteBranch;

  /// Links the branch to [remoteBranch].
  final VoidCallback? onLink;

  final RepoStatus status;
  final bool busy;
  final ValueChanged<PullStrategy> onPull;
  final VoidCallback onChoosePull;
  final VoidCallback onPush;
  final VoidCallback onSwitchBranch;

  @override
  Widget build(BuildContext context) {
    final upstream = status.upstream ?? 'the remote';
    String commits(int n) => plural(n, 'commit');

    final (
      String title,
      String body,
      List<Widget> actions,
    ) = switch (status.syncState) {
      SyncState.upToDate => ('', '', const <Widget>[]),
      SyncState.behind => (
        'You’re ${commits(status.behind)} behind $upstream',
        'Pull now to get the latest work — the sooner you do, the smaller any conflicts will be.',
        [
          FilledButton(
            onPressed: busy ? null : () => onPull(PullStrategy.fastForwardOnly),
            child: const Text('Pull'),
          ),
          TextButton(
            onPressed: busy ? null : onChoosePull,
            child: const Text('Other options'),
          ),
        ],
      ),
      SyncState.diverged => (
        'Your branch and $upstream have both moved',
        'You have ${commits(status.ahead)} the remote doesn’t, and it has ${commits(status.behind)} you don’t. '
            'Rebase puts your work on top (tidy, linear history); merge joins both with a merge commit '
            '(nothing is rewritten).',
        [
          FilledButton(
            onPressed: busy ? null : () => onPull(PullStrategy.rebase),
            child: const Text('Pull + Rebase'),
          ),
          OutlinedButton(
            onPressed: busy ? null : () => onPull(PullStrategy.merge),
            child: const Text('Pull + Merge'),
          ),
        ],
      ),
      SyncState.ahead => (
        'You have ${commits(status.ahead)} to push',
        'They’re only on this computer right now. Push to back them up and share them.',
        [
          FilledButton(
            onPressed: busy ? null : onPush,
            child: const Text('Push'),
          ),
        ],
      ),
      SyncState.noUpstream when remoteBranch != null && onLink != null => (
        'This branch is already online as $remoteBranch',
        'It just isn’t linked on this computer yet, so Gitty couldn’t compare '
            'them. Link them and Pull, Push and the “behind” hints work as usual.',
        [
          FilledButton.icon(
            onPressed: busy ? null : onLink,
            icon: const Icon(Icons.link_rounded, size: 18),
            label: const Text('Link them'),
          ),
        ],
      ),
      SyncState.noUpstream =>
        status.hasCommits
            ? (
                'This branch isn’t online yet',
                'Publish it to the remote so it’s backed up and others can see it.',
                [
                  FilledButton(
                    onPressed: busy ? null : onPush,
                    child: const Text('Publish branch'),
                  ),
                ],
              )
            : ('', '', const <Widget>[]),
      SyncState.detached => (
        'You’re not on a branch',
        'You’re looking at a specific commit (“detached HEAD”). New commits here are easy to lose — '
            'switch to a branch or create one first.',
        [
          FilledButton(
            onPressed: busy ? null : onSwitchBranch,
            child: const Text('Switch branch'),
          ),
        ],
      ),
    };

    if (title.isEmpty) return const SizedBox.shrink();

    final colors = StatusColors.forSync(
      status.syncState,
      Theme.of(context).colorScheme,
    );
    final theme = Theme.of(context);
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
            Icon(Icons.tips_and_updates_outlined, color: colors.foreground),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
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
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  actions[i],
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
