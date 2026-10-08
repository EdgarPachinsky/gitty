import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/gitty_exception.dart';
import '../../core/utils/time_ago.dart';
import '../../core/widgets/state_views.dart';
import '../../services/auth/git_provider.dart';
import '../../services/git/git_service.dart';
import '../../services/git/repo_scanner.dart';
import '../../services/service_providers.dart';
import '../account/account_controller.dart';
import 'tracked_repos_controller.dart';

/// Repositories found on disk that aren't tracked yet.
final repoScanProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  final found = await ref.watch(repoScannerProvider).scan();
  final tracked = ref.read(trackedReposProvider).map((r) => r.path).toSet();
  return found.where((path) => !tracked.contains(path)).toList();
});

/// Lets the user pick a folder and adds the repository in it.
Future<void> pickAndAddRepository(BuildContext context, WidgetRef ref) async {
  final path = await getDirectoryPath(confirmButtonText: 'Add repository');
  if (path == null || !context.mounted) return;
  try {
    final repo = await ref.read(trackedReposProvider.notifier).addFolder(path);
    final isRepo = await ref.read(gitServiceProvider).isRepository(repo.path);
    if (context.mounted)
      showFriendlySnack(
        context,
        message: isRepo
            ? 'Added ${repo.name}.'
            : 'Added ${repo.name}. Open it to set up Git.',
      );
  } catch (e) {
    final error = toGittyException(e);
    if (context.mounted)
      showFriendlySnack(context, message: error.message, error: error);
  }
}

/// Scans the machine and lets the user choose which repositories to add.
Future<void> showScanDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ScanDialog(),
  );
}

class _ScanDialog extends ConsumerStatefulWidget {
  const _ScanDialog();

  @override
  ConsumerState<_ScanDialog> createState() => _ScanDialogState();
}

class _ScanDialogState extends ConsumerState<_ScanDialog> {
  Set<String>? _selected;

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(repoScanProvider);
    return AlertDialog(
      title: const Text('Repositories on this computer'),
      content: SizedBox(
        width: 520,
        height: 380,
        child: scan.when(
          loading: () =>
              const LoadingView(message: 'Looking around for repositories…'),
          error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(repoScanProvider),
          ),
          data: (paths) {
            if (paths.isEmpty) {
              return const EmptyState(
                icon: Icons.travel_explore,
                title: 'Nothing new found',
                message:
                    'Every repository we could find is already in Gitty. '
                    'You can still add a folder manually.',
              );
            }
            final selected = _selected ??= paths.toSet();
            return RepoPathChecklist(
              paths: paths,
              selected: selected,
              onChanged: (s) => setState(() => _selected = s),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (_selected?.isEmpty ?? true)
              ? null
              : () async {
                  final count = _selected!.length;
                  await ref
                      .read(trackedReposProvider.notifier)
                      .addRoots(_selected!);
                  if (!context.mounted) return;
                  showFriendlySnack(
                    context,
                    message:
                        'Added ${plural(count, 'repository', 'repositories')}.',
                  );
                  Navigator.pop(context);
                },
          child: Text(
            _selected == null || _selected!.isEmpty
                ? 'Add'
                : 'Add ${_selected!.length}',
          ),
        ),
      ],
    );
  }
}

/// Checkbox list of repository paths, with select all/none.
class RepoPathChecklist extends StatelessWidget {
  const RepoPathChecklist({
    super.key,
    required this.paths,
    required this.selected,
    required this.onChanged,
  });

  final List<String> paths;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final home = RepoScanner.homeDirectory;
    String pretty(String path) => home != null && p.isWithin(home, path)
        ? '~${path.substring(home.length)}'
        : path;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${selected.length} of ${paths.length} selected',
              style: theme.textTheme.labelLarge,
            ),
            const Spacer(),
            TextButton(
              onPressed: () => onChanged(paths.toSet()),
              child: const Text('All'),
            ),
            TextButton(
              onPressed: () => onChanged(<String>{}),
              child: const Text('None'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            itemCount: paths.length,
            itemBuilder: (context, i) {
              final path = paths[i];
              return CheckboxListTile(
                dense: true,
                value: selected.contains(path),
                controlAffinity: ListTileControlAffinity.leading,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                title: Text(
                  p.basename(path),
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: Text(
                  pretty(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onChanged: (checked) {
                  final next = {...selected};
                  checked == true ? next.add(path) : next.remove(path);
                  onChanged(next);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Clone a repository by URL (or from the connected GitHub account).
/// Returns the new repository path, already added to Gitty.
Future<String?> showCloneDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _CloneDialog(),
  );
}

class _CloneDialog extends ConsumerStatefulWidget {
  const _CloneDialog();

  @override
  ConsumerState<_CloneDialog> createState() => _CloneDialogState();
}

class _CloneDialogState extends ConsumerState<_CloneDialog> {
  final _url = TextEditingController();
  late String _destination = _defaultDestination();
  bool _cloning = false;
  GittyException? _error;

  static String _defaultDestination() {
    final home = RepoScanner.homeDirectory ?? Directory.current.path;
    for (final name in [
      'Developer',
      'Projects',
      'projects',
      'Code',
      'code',
      'dev',
    ]) {
      final candidate = p.join(home, name);
      if (Directory(candidate).existsSync()) return candidate;
    }
    return home;
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _chooseDestination() async {
    final path = await getDirectoryPath(
      initialDirectory: _destination,
      confirmButtonText: 'Clone here',
    );
    if (path != null) setState(() => _destination = path);
  }

  Future<void> _clone() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(
        () => _error = const GittyException('Paste a repository URL first.'),
      );
      return;
    }
    setState(() {
      _cloning = true;
      _error = null;
    });
    try {
      final path = await ref.read(gitServiceProvider).clone(url, _destination);
      await ref.read(trackedReposProvider.notifier).addRoots([path]);
      if (mounted) Navigator.pop(context, path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _cloning = false;
          _error = toGittyException(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = ref.watch(accountProvider).value;
    final folderName = _url.text.trim().isEmpty
        ? ''
        : GitService.repoNameFromUrl(_url.text);

    return AlertDialog(
      title: const Text('Clone a repository'),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              enabled: !_cloning,
              decoration: const InputDecoration(
                labelText: 'Repository URL',
                hintText: 'https://github.com/owner/repo.git',
                prefixIcon: Icon(Icons.link),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _clone(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.folder_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    folderName.isEmpty
                        ? _destination
                        : p.join(_destination, folderName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                TextButton(
                  onPressed: _cloning ? null : _chooseDestination,
                  child: const Text('Change…'),
                ),
              ],
            ),
            if (account != null) ...[
              const SizedBox(height: 8),
              Text('From your GitHub', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              SizedBox(
                height: 180,
                child: _RemoteRepoList(
                  onPick: (r) => setState(() => _url.text = r.cloneUrl),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                [
                  _error!.message,
                  if (_error!.hint != null) _error!.hint!,
                ].join(' '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (_cloning) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 6),
              Text(
                'Cloning… big repositories can take a minute.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cloning ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _cloning ? null : _clone,
          icon: const Icon(Icons.download_rounded),
          label: const Text('Clone'),
        ),
      ],
    );
  }
}

class _RemoteRepoList extends ConsumerWidget {
  const _RemoteRepoList({required this.onPick});

  final ValueChanged<RemoteRepository> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(remoteReposProvider);
    return repos.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(
        error: e,
        compact: true,
        onRetry: () => ref.invalidate(remoteReposProvider),
      ),
      data: (list) => list.isEmpty
          ? const Center(child: Text('No repositories found on your account.'))
          : ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final r = list[i];
                return ListTile(
                  dense: true,
                  leading: Icon(
                    r.isPrivate ? Icons.lock_outline : Icons.public,
                    size: 18,
                  ),
                  title: Text(r.fullName),
                  subtitle: r.description == null
                      ? null
                      : Text(
                          r.description!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  onTap: () => onPick(r),
                );
              },
            ),
    );
  }
}
