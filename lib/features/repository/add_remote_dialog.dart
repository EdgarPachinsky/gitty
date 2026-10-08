import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/gitty_exception.dart';
import '../../core/utils/time_ago.dart';
import '../../core/widgets/state_views.dart';
import '../../services/auth/git_provider.dart';
import '../../services/service_providers.dart';
import '../account/account_controller.dart';
import '../account/github_connect_card.dart';
import '../dashboard/tracked_repos_controller.dart';
import 'repo_actions_controller.dart';

/// Lets the user connect `origin` by pasting a URL, picking one of their
/// GitHub repositories, or creating a brand-new GitHub repository.
/// Returns the success message, or null if cancelled.
Future<String?> showAddRemoteDialog(
  BuildContext context, {
  required String repoPath,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _AddRemoteDialog(repoPath: repoPath),
  );
}

enum _Mode { existing, create }

class _AddRemoteDialog extends ConsumerStatefulWidget {
  const _AddRemoteDialog({required this.repoPath});

  final String repoPath;

  @override
  ConsumerState<_AddRemoteDialog> createState() => _AddRemoteDialogState();
}

class _AddRemoteDialogState extends ConsumerState<_AddRemoteDialog> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _description = TextEditingController();

  _Mode _mode = _Mode.existing;

  /// Owner for a new repository; null = the personal account.
  String? _owner;
  bool _private = true;
  bool _pushAfterCreate = true;
  bool _creating = false;
  GittyException? _error;

  @override
  void initState() {
    super.initState();
    _name.text = suggestRepoName(p.basename(widget.repoPath));
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  RepoActionsController get _actions =>
      ref.read(repoActionsProvider(widget.repoPath).notifier);

  bool get _hasCommits =>
      ref.read(repoSnapshotProvider(widget.repoPath)).value?.status.hasCommits ??
      false;

  Future<void> _connect() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(
        () => _error = const GittyException(
          'Paste a repository URL or pick one from GitHub first.',
        ),
      );
      return;
    }
    setState(() => _error = null);
    final outcome = await _actions.connectRemote(url);
    if (!mounted) return;
    if (outcome.ok) {
      Navigator.pop(context, outcome.message);
    } else {
      setState(() => _error = outcome.error);
    }
  }

  /// Creates the repository on GitHub, adds it as origin and (optionally)
  /// pushes the current branch.
  Future<void> _createAndConnect() async {
    final name = _name.text.trim();
    final problem = validateRepoName(name);
    if (problem != null) {
      setState(() => _error = GittyException(problem));
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });

    final RemoteRepository repo;
    try {
      repo = await ref
          .read(githubProvider)
          .createRepository(
            name: name,
            description: _description.text,
            isPrivate: _private,
            organization: _owner,
          );
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = toGittyException(e);
        });
      }
      return;
    }
    ref.invalidate(remoteReposProvider);

    final connected = await _actions.connectRemote(repo.cloneUrl);
    if (!mounted) return;
    if (!connected.ok) {
      // The repository exists now — let the user retry with its URL.
      setState(() {
        _creating = false;
        _mode = _Mode.existing;
        _url.text = repo.cloneUrl;
        _error = connected.error;
      });
      return;
    }

    var message = 'Created ${repo.fullName} on GitHub and added it as origin.';
    if (_pushAfterCreate && _hasCommits) {
      final pushed = await _actions.push();
      if (!mounted) return;
      message = pushed.ok
          ? 'Created ${repo.fullName} on GitHub and pushed your commits there.'
          : '$message The first push didn’t go through yet: ${pushed.message}';
    } else {
      message = '$message Commit, then Publish to send your work there.';
    }
    Navigator.pop(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = ref.watch(accountProvider);
    final actionBusy = ref.watch(repoActionsProvider(widget.repoPath));
    final busy = _creating || actionBusy != null;
    final hasCommits =
        ref
            .watch(repoSnapshotProvider(widget.repoPath))
            .value
            ?.status
            .hasCommits ??
        false;
    final connectedAccount = account.value;
    final mode = connectedAccount == null ? _Mode.existing : _mode;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: const Text('Add origin'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Where should this repository live online? Paste a URL, pick '
                'one of your GitHub repositories, or create a new one.',
                style: muted,
              ),
              const SizedBox(height: 16),
              if (connectedAccount != null) ...[
                SegmentedButton<_Mode>(
                  segments: const [
                    ButtonSegment(
                      value: _Mode.existing,
                      icon: Icon(Icons.link),
                      label: Text('Use existing'),
                    ),
                    ButtonSegment(
                      value: _Mode.create,
                      icon: Icon(Icons.add_rounded),
                      label: Text('Create new on GitHub'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: busy
                      ? null
                      : (s) => setState(() {
                          _mode = s.first;
                          _error = null;
                        }),
                ),
                const SizedBox(height: 16),
              ],
              if (mode == _Mode.existing) ...[
                TextField(
                  controller: _url,
                  autofocus: true,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Remote URL',
                    hintText: 'https://github.com/owner/repo.git',
                    prefixIcon: Icon(Icons.link),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _connect(),
                ),
                const SizedBox(height: 20),
                if (connectedAccount != null) ...[
                  Text('From your GitHub', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  _GitHubRepoPicker(
                    selectedUrl: _url.text.trim(),
                    enabled: !busy,
                    onPick: (r) => setState(() {
                      _url.text = r.cloneUrl;
                      _error = null;
                    }),
                  ),
                ] else if (!account.isLoading) ...[
                  Text(
                    'Want to pick one of your GitHub repositories, or create a '
                    'new one right here? Connect your account:',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const GitHubConnectCard(),
                ],
              ] else
                _CreateRepoForm(
                  account: connectedAccount!,
                  name: _name,
                  description: _description,
                  owner: _owner,
                  isPrivate: _private,
                  showPushOption: hasCommits,
                  pushAfterCreate: _pushAfterCreate,
                  enabled: !busy,
                  onOwnerChanged: (o) => setState(() => _owner = o),
                  onPrivateChanged: (v) => setState(() => _private = v),
                  onPushChanged: (v) => setState(() => _pushAfterCreate = v),
                  onChanged: () => setState(() => _error = null),
                  onSubmit: _createAndConnect,
                ),
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
              if (busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 6),
                Text(
                  _creating && actionBusy == null
                      ? 'Creating the repository on GitHub…'
                      : actionBusy == GitAction.push
                      ? 'Pushing your commits…'
                      : 'Connecting and checking the remote…',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Not now'),
        ),
        if (mode == _Mode.existing)
          FilledButton.icon(
            onPressed: busy || _url.text.trim().isEmpty ? null : _connect,
            icon: const Icon(Icons.add_link_rounded),
            label: const Text('Add origin'),
          )
        else
          FilledButton.icon(
            onPressed: busy || validateRepoName(_name.text.trim()) != null
                ? null
                : _createAndConnect,
            icon: const Icon(Icons.rocket_launch_outlined),
            label: const Text('Create & add origin'),
          ),
      ],
    );
  }
}

/// Owner / name / description / visibility for a new GitHub repository.
class _CreateRepoForm extends ConsumerWidget {
  const _CreateRepoForm({
    required this.account,
    required this.name,
    required this.description,
    required this.owner,
    required this.isPrivate,
    required this.showPushOption,
    required this.pushAfterCreate,
    required this.enabled,
    required this.onOwnerChanged,
    required this.onPrivateChanged,
    required this.onPushChanged,
    required this.onChanged,
    required this.onSubmit,
  });

  final ProviderAccount account;
  final TextEditingController name;
  final TextEditingController description;
  final String? owner;
  final bool isPrivate;
  final bool showPushOption;
  final bool pushAfterCreate;
  final bool enabled;
  final ValueChanged<String?> onOwnerChanged;
  final ValueChanged<bool> onPrivateChanged;
  final ValueChanged<bool> onPushChanged;
  final VoidCallback onChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final owners = ref.watch(repoOwnersProvider).value;
    final orgs = [
      for (final o in owners ?? const <RepoOwner>[])
        if (o.isOrganization) o.login,
    ];
    final nameProblem = name.text.trim().isEmpty
        ? null
        : validateRepoName(name.text.trim());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 190,
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Owner',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    // '' = the personal account.
                    value: orgs.contains(owner) ? owner! : '',
                    onChanged: enabled
                        ? (v) => onOwnerChanged(
                            v == null || v.isEmpty ? null : v,
                          )
                        : null,
                    items: [
                      DropdownMenuItem<String>(
                        value: '',
                        child: Text(
                          account.username,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (final org in orgs)
                        DropdownMenuItem<String>(
                          value: org,
                          child: Text(org, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 16, 10, 0),
              child: Text('/', style: theme.textTheme.titleLarge),
            ),
            Expanded(
              child: TextField(
                controller: name,
                autofocus: true,
                enabled: enabled,
                decoration: InputDecoration(
                  labelText: 'Repository name',
                  errorText: nameProblem,
                ),
                onChanged: (_) => onChanged(),
                onSubmitted: (_) => onSubmit(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: description,
          enabled: enabled,
          decoration: const InputDecoration(
            labelText: 'Description (optional)',
            prefixIcon: Icon(Icons.notes_rounded),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.lock_outline, size: 18),
                  label: Text('Private'),
                ),
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.public, size: 18),
                  label: Text('Public'),
                ),
              ],
              selected: {isPrivate},
              onSelectionChanged: enabled
                  ? (s) => onPrivateChanged(s.first)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                isPrivate
                    ? 'Only you (and people you invite) can see it.'
                    : 'Anyone on the internet can see it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        if (showPushOption) ...[
          const SizedBox(height: 8),
          CheckboxListTile(
            value: pushAfterCreate,
            onChanged: enabled ? (v) => onPushChanged(v ?? false) : null,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Push my commits right away'),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Gitty creates it empty (no README), so your first push goes through '
          'cleanly.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Searchable list of the connected account's repositories.
class _GitHubRepoPicker extends ConsumerStatefulWidget {
  const _GitHubRepoPicker({
    required this.selectedUrl,
    required this.enabled,
    required this.onPick,
  });

  final String selectedUrl;
  final bool enabled;
  final ValueChanged<RemoteRepository> onPick;

  @override
  ConsumerState<_GitHubRepoPicker> createState() => _GitHubRepoPickerState();
}

class _GitHubRepoPickerState extends ConsumerState<_GitHubRepoPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repos = ref.watch(remoteReposProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          enabled: widget.enabled,
          decoration: const InputDecoration(
            isDense: true,
            hintText: 'Search your repositories',
            prefixIcon: Icon(Icons.search, size: 20),
          ),
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 240,
          child: repos.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(
              error: e,
              compact: true,
              onRetry: () => ref.invalidate(remoteReposProvider),
            ),
            data: (all) {
              final list = _query.isEmpty
                  ? all
                  : all
                        .where(
                          (r) =>
                              r.fullName.toLowerCase().contains(_query) ||
                              (r.description?.toLowerCase().contains(_query) ??
                                  false),
                        )
                        .toList();
              if (all.isEmpty) {
                return const Center(
                  child: Text(
                    'No repositories on your account yet. Switch to '
                    '“Create new on GitHub” above to make one.',
                    textAlign: TextAlign.center,
                  ),
                );
              }
              if (list.isEmpty) {
                return const Center(child: Text('No matches.'));
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final r = list[i];
                  final selected =
                      r.cloneUrl == widget.selectedUrl ||
                      (r.sshUrl != null && r.sshUrl == widget.selectedUrl);
                  return ListTile(
                    dense: true,
                    enabled: widget.enabled,
                    selected: selected,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    leading: Icon(
                      r.isPrivate ? Icons.lock_outline : Icons.public,
                      size: 18,
                    ),
                    title: Text(r.fullName),
                    subtitle: Text(
                      [
                        if (r.description != null && r.description!.isNotEmpty)
                          r.description!,
                        if (r.updatedAt != null)
                          'updated ${timeAgo(r.updatedAt!)}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: selected
                        ? Icon(
                            Icons.check_circle,
                            size: 20,
                            color: theme.colorScheme.primary,
                          )
                        : null,
                    onTap: () => widget.onPick(r),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
