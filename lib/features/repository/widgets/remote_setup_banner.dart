import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../services/git/git_models.dart';

/// Shown when a repository has no remote yet: nudges the user to add
/// `origin` so their work can be pushed and backed up.
///
/// Styled like [SyncBanner] so the two feel like one family.
class RemoteSetupBanner extends StatelessWidget {
  const RemoteSetupBanner({
    super.key,
    required this.busy,
    required this.onAddOrigin,
  });

  final bool busy;
  final VoidCallback onAddOrigin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.forSync(SyncState.ahead, theme.colorScheme);
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
            Icon(Icons.cloud_off_outlined, color: colors.foreground),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Add an origin for this repository',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'It only lives on this computer right now. Create a new '
                    'GitHub repository, pick an existing one, or paste any Git '
                    'URL — so you can push, pull and keep it backed up.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.foreground,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: busy ? null : onAddOrigin,
              icon: const Icon(Icons.add_link_rounded, size: 18),
              label: const Text('Add origin'),
            ),
          ],
        ),
      ),
    );
  }
}
