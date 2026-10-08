import 'package:flutter/material.dart';

import '../../services/git/git_models.dart';
import '../theme/app_theme.dart';

/// Small colored pill describing how a branch relates to its upstream.
class SyncStatusPill extends StatelessWidget {
  const SyncStatusPill({super.key, required this.status, this.remoteBranch});

  final RepoStatus status;

  /// Same-named branch on a remote while there's no upstream link: the
  /// branch is online, just not linked.
  final String? remoteBranch;

  static (IconData, String) describe(RepoStatus s, {String? remoteBranch}) =>
      s.syncState == SyncState.noUpstream && remoteBranch != null
      ? (Icons.link_off_rounded, 'Not linked')
      : switch (s.syncState) {
    SyncState.upToDate => (Icons.check_circle_outline, 'Up to date'),
    SyncState.ahead => (Icons.arrow_upward, '${s.ahead} to push'),
    SyncState.behind => (Icons.arrow_downward, '${s.behind} behind'),
    SyncState.diverged => (Icons.call_split, 'Diverged'),
    SyncState.noUpstream => (Icons.cloud_off_outlined, 'Not published'),
    SyncState.detached => (Icons.link_off, 'Detached'),
  };

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.forSync(
      status.syncState,
      Theme.of(context).colorScheme,
    );
    final (icon, label) = describe(status, remoteBranch: remoteBranch);
    return Pill(
      icon: icon,
      label: label,
      background: colors.background,
      foreground: colors.foreground,
    );
  }
}

/// Generic compact pill.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.icon,
    this.background,
    this.foreground,
  });

  final String label;
  final IconData? icon;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = foreground ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
