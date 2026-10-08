import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../services/git/git_models.dart';
import '../../services/service_providers.dart';
import '../../services/storage/repo_repository.dart';
import '../repository/repo_actions_controller.dart';
import 'tracked_repos_controller.dart';

/// The hosting service's logo (GitHub, GitLab, Bitbucket, Azure DevOps, or a
/// generic Git mark), worked out from the remote URL. Hover for details;
/// click to open the repository in the browser. Nothing when there's no
/// remote.
class RemoteHostLogo extends ConsumerWidget {
  const RemoteHostLogo({super.key, required this.repoPath, this.size = 18});

  final String repoPath;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(remoteHostProvider(repoPath)).value;
    if (host == null) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.onSurfaceVariant;

    final icon = remoteHostIcon(host.kind, size: size, color: color);

    final web = host.webUrl;
    final where = web == null
        ? host.url
        : '${web.host}${web.path}';
    return Tooltip(
      message: web == null
          ? '${host.label} · ${host.remoteName}: $where'
          : '${host.label} · $where\nClick to open in your browser',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: web == null
            ? null
            : () => ref.read(systemLauncherProvider).openUrl(web),
        child: Padding(padding: const EdgeInsets.all(4), child: icon),
      ),
    );
  }
}

/// Icon for a hosting service; `null` means "no remote" (only on this
/// computer). Shared by the card logos and the host filter buttons.
Widget remoteHostIcon(RemoteHostKind? kind, {double size = 18, Color? color}) =>
    switch (kind) {
      RemoteHostKind.github => FaIcon(FontAwesomeIcons.github, size: size, color: color),
      RemoteHostKind.gitlab => FaIcon(FontAwesomeIcons.gitlab, size: size, color: color),
      RemoteHostKind.bitbucket => FaIcon(FontAwesomeIcons.bitbucket, size: size, color: color),
      RemoteHostKind.azure => FaIcon(FontAwesomeIcons.microsoft, size: size, color: color),
      RemoteHostKind.otherGit => FaIcon(FontAwesomeIcons.gitAlt, size: size, color: color),
      RemoteHostKind.localFolder => Icon(Icons.folder_shared_outlined, size: size, color: color),
      null => Icon(Icons.cloud_off_outlined, size: size, color: color),
    };

/// "GitHub", "Other Git servers", "No remote", … for the filter buttons.
String remoteHostFilterLabel(RemoteHostKind? kind) => switch (kind) {
  RemoteHostKind.otherGit => 'Other Git servers',
  RemoteHostKind.localFolder => 'Remote in a local folder',
  null => 'No remote (only on this computer)',
  final RemoteHostKind k => k.label,
};

/// Lets the user pick the title shown in Gitty. Returns true when saved.
Future<bool> showRenameRepoDialog(
  BuildContext context,
  WidgetRef ref,
  TrackedRepo repo,
) async {
  final controller = TextEditingController(text: repo.displayName ?? '');
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) {
      void save() => Navigator.pop(context, true);
      return AlertDialog(
        title: const Text('Rename in Gitty'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pick the name you want to see in your list. Only Gitty shows '
                'it — the folder on your disk keeps its name.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Title',
                  hintText: repo.name,
                  helperText: 'Leave empty to use the folder name (${repo.name}).',
                  prefixIcon: const Icon(Icons.label_outline),
                ),
                onSubmitted: (_) => save(),
              ),
            ],
          ),
        ),
        actions: [
          if (repo.displayName != null)
            TextButton(
              onPressed: () {
                controller.clear();
                save();
              },
              child: const Text('Use folder name'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: save, child: const Text('Save')),
        ],
      );
    },
  );
  // Not disposed here: the dialog may still be animating out.
  final title = controller.text;
  if (saved != true) return false;
  await ref.read(trackedReposProvider.notifier).rename(repo.path, title);
  return true;
}

/// Asks, then removes [repo] from Gitty's list. The folder isn't touched.
Future<void> confirmRemoveRepo(
  BuildContext context,
  WidgetRef ref,
  TrackedRepo repo,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remove “${repo.title}” from Gitty?'),
      content: const Text(
        'The folder and every file in it stay exactly where they are — Gitty '
        'just stops showing it. You can add it again anytime.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.playlist_remove_rounded, size: 18),
          label: const Text('Remove from Gitty'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  // The card asking for this disappears, so grab the messenger first.
  final messenger = ScaffoldMessenger.maybeOf(context);
  await ref.read(trackedReposProvider.notifier).remove(repo.path);
  messenger?.showSnackBar(
    SnackBar(
      content: Text(
        'Removed “${repo.title}” from Gitty. Your files weren’t touched.',
      ),
    ),
  );
}
