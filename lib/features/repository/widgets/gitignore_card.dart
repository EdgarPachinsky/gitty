import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/time_ago.dart';
import '../../../services/git/gitignore_templates.dart';
import '../../../services/service_providers.dart';
import '../gitignore_dialog.dart';
import '../repo_actions_controller.dart';

/// Project types Gitty recognises in the repository's top-level folder.
final _detectedTemplatesProvider = FutureProvider.autoDispose
    .family<Set<String>, String>((ref, path) async {
      final names = await ref.watch(gitServiceProvider).topLevelNames(path);
      return detectGitignoreTemplates(names);
    });

/// "Add a .gitignore" when the repository has none; a compact summary with
/// "Add more rules" when it does. Styled like [InsightsCard].
class GitignoreCard extends ConsumerWidget {
  const GitignoreCard({super.key, required this.repoPath, required this.onOpen});

  final String repoPath;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final gitignore = ref.watch(gitignoreProvider(repoPath));
    final busy = ref.watch(repoActionsProvider(repoPath)) != null;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // Nothing to show until we know whether the file exists.
    if (!gitignore.hasValue) return const SizedBox.shrink();
    final content = gitignore.value;

    if (content != null) {
      final rules = gitignoreRules(content).length;
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
          child: Row(
            children: [
              Icon(
                Icons.visibility_off_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('.gitignore', style: theme.textTheme.titleSmall),
                    Text(
                      rules == 0
                          ? 'Empty — Git isn’t skipping anything yet.'
                          : 'Git skips files matching ${plural(rules, 'rule')}.',
                      style: muted,
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: busy ? null : onOpen,
                child: const Text('Add more…'),
              ),
            ],
          ),
        ),
      );
    }

    final detected = ref.watch(_detectedTemplatesProvider(repoPath)).value;
    final suggested = suggestedGitignoreTemplates(detected ?? const <String>{});
    final projectLabels = [
      for (final t in gitignoreTemplates)
        if (detected?.contains(t.id) ?? false) t.label,
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('Add a .gitignore', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Tooltip(
                  message:
                      'Files matching .gitignore stay on your computer but are '
                      'never committed.',
                  child: Icon(
                    Icons.help_outline_rounded,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              projectLabels.isEmpty
                  ? 'Keep build output, dependencies, secrets and system '
                        'clutter out of your commits.'
                  : 'Looks like a ${projectLabels.join(' + ')} project. Keep its '
                        'build output, dependencies, secrets and system clutter '
                        'out of your commits.',
              style: muted,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in gitignoreTemplates)
                  if (suggested.contains(t.id))
                    Chip(
                      avatar: Icon(gitignoreIcon(t.id), size: 16),
                      label: Text(t.label),
                      visualDensity: VisualDensity.compact,
                    ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              onPressed: busy ? null : onOpen,
              icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
              label: const Text('Choose what to ignore'),
            ),
          ],
        ),
      ),
    );
  }
}
