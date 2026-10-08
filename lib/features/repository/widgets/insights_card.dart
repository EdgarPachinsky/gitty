import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/time_ago.dart';
import '../repo_actions_controller.dart';

/// Small, local-only health metrics for a repository.
class InsightsCard extends ConsumerWidget {
  const InsightsCard({super.key, required this.repoPath});

  final String repoPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final insights = ref.watch(repoInsightsProvider(repoPath));
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('Insights', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Tooltip(
                  message:
                      'Counted on this computer only. Nothing is ever uploaded.',
                  child: Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (insights.isEmpty)
              Text(
                'Insights appear as you commit, pull and push with Gitty.',
                style: muted,
              )
            else
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _Stat(
                    label: 'Commits this week',
                    value: '${insights.commitsLast7Days}',
                  ),
                  _Stat(
                    label: 'Commits (30 days)',
                    value: '${insights.commitsLast30Days}',
                  ),
                  if (insights.averageTimeBetweenCommits != null)
                    _Stat(
                      label: 'Between commits',
                      value: humanDuration(insights.averageTimeBetweenCommits!),
                    ),
                  if (insights.averagePullToPush != null)
                    _Stat(
                      label: 'Pull → push',
                      value: humanDuration(insights.averagePullToPush!),
                    ),
                  if (insights.dirtyShare != null)
                    _Stat(
                      label: 'Had uncommitted work',
                      value: '${(insights.dirtyShare! * 100).round()}%',
                    ),
                  if (insights.lastPull != null)
                    _Stat(
                      label: 'Last pull',
                      value: timeAgo(insights.lastPull!),
                    ),
                  if (insights.lastPush != null)
                    _Stat(
                      label: 'Last push',
                      value: timeAgo(insights.lastPush!),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 132,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
