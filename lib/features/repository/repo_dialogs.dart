import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/state_views.dart';
import '../../core/utils/time_ago.dart';
import '../../services/git/git_models.dart';
import '../../services/git/workflow_models.dart';
import '../../services/service_providers.dart';
import 'repo_actions_controller.dart';
import 'widgets/branch_tree_view.dart';

/// Explains the three pull strategies and returns the user's choice.
Future<PullStrategy?> showPullOptionsDialog(
  BuildContext context, {
  required RepoStatus status,
}) {
  final recommended = status.syncState == SyncState.diverged
      ? PullStrategy.rebase
      : PullStrategy.fastForwardOnly;

  Widget option(
    PullStrategy s,
    IconData icon,
    String title,
    String explanation,
  ) {
    final isRecommended = s == recommended;
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Card(
          color: isRecommended ? theme.colorScheme.primaryContainer : null,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 6,
            ),
            leading: Icon(icon),
            title: Row(
              children: [
                Text(title),
                if (isRecommended) ...[
                  const SizedBox(width: 8),
                  Text(
                    'Recommended',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
            subtitle: Text(explanation),
            onTap: () => Navigator.pop(context, s),
          ),
        );
      },
    );
  }

  return showDialog<PullStrategy>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('How should I pull?'),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status.syncState == SyncState.diverged)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'You have ${status.ahead} local commit(s) and the remote has ${status.behind} new one(s). '
                  'Pick how to combine them:',
                ),
              ),
            option(
              PullStrategy.fastForwardOnly,
              Icons.fast_forward_rounded,
              'Pull',
              'Safest. Only moves your branch forward; stops if histories have split.',
            ),
            const SizedBox(height: 8),
            option(
              PullStrategy.rebase,
              Icons.low_priority_rounded,
              'Pull + Rebase',
              'Puts your local commits on top of the remote ones. Keeps history in a straight line.',
            ),
            const SizedBox(height: 8),
            option(
              PullStrategy.merge,
              Icons.merge_rounded,
              'Pull + Merge',
              'Adds a merge commit that joins both histories. Nothing gets rewritten.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

/// What the user picked in the "Create a new branch" dialog.
class NewBranchRequest {
  const NewBranchRequest({
    required this.name,
    required this.from,
    required this.switchToIt,
    required this.push,
  });

  final String name;

  /// Branch to start from; null = where you are now.
  final String? from;
  final bool switchToIt;
  final bool push;
}

/// Asks for a new branch name, where it starts from, and whether to switch
/// to it and/or push it. Returns null when cancelled.
Future<NewBranchRequest?> showNewBranchDialog(
  BuildContext context, {
  required String repoPath,
  String? fromBranch,
}) {
  return showDialog<NewBranchRequest>(
    context: context,
    builder: (_) =>
        _NewBranchDialog(repoPath: repoPath, currentBranch: fromBranch),
  );
}

class _NewBranchDialog extends ConsumerStatefulWidget {
  const _NewBranchDialog({required this.repoPath, this.currentBranch});

  final String repoPath;
  final String? currentBranch;

  @override
  ConsumerState<_NewBranchDialog> createState() => _NewBranchDialogState();
}

class _NewBranchDialogState extends ConsumerState<_NewBranchDialog> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  bool _switch = true;
  bool _push = false;

  /// Branch whose name was just copied (shows a ✓ for a moment).
  String? _copied;

  /// Selected starting branch; '' = where you are now (detached HEAD).
  late String _from = widget.currentBranch ?? '';

  /// Friendly normalisation: spaces → dashes, strip characters git rejects.
  static String normalize(String input) => input
      .trim()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[~^:?*\[\]\\]'), '')
      .replaceAll(RegExp(r'\.{2,}'), '.')
      .replaceAll(RegExp(r'/{2,}'), '/');

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  /// "feature/login" → "feature/"; "dev" → "dev-". (Git can't have both
  /// "dev" and "dev/something", so a plain name gets a dash.)
  static String prefixFor(String branch) {
    final slash = branch.lastIndexOf('/');
    return slash > 0 ? branch.substring(0, slash + 1) : '$branch-';
  }

  void _fillName(String text) {
    _name.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {});
    _nameFocus.requestFocus();
  }

  Future<void> _copy(String branch) async {
    await Clipboard.setData(ClipboardData(text: branch));
    if (!mounted) return;
    setState(() => _copied = branch);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted && _copied == branch) setState(() => _copied = null);
  }

  /// Trailing part of a "Start from" option: an optional label plus
  /// copy / use as name / use as prefix.
  Widget _entryTrailing(String branch, {String? label}) {
    final theme = Theme.of(context);
    Widget action(IconData icon, String tip, VoidCallback onTap) => IconButton(
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
    );
    final prefix = prefixFor(branch);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(width: 6),
        ],
        action(
          _copied == branch ? Icons.check_rounded : Icons.copy_rounded,
          _copied == branch ? 'Copied' : 'Copy name',
          () => _copy(branch),
        ),
        action(
          Icons.drive_file_rename_outline_rounded,
          'Use as the new branch name',
          () => _fillName(branch),
        ),
        action(
          Icons.subdirectory_arrow_right_rounded,
          'Start the new name with “$prefix”',
          () => _fillName(prefix),
        ),
      ],
    );
  }

  void _submit({required bool canPush}) {
    final name = normalize(_name.text);
    if (name.isEmpty) return;
    Navigator.pop(
      context,
      NewBranchRequest(
        name: name,
        from: _from.isEmpty || _from == widget.currentBranch ? null : _from,
        switchToIt: _switch,
        push: _push && canPush,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final normalized = normalize(_name.text);
    final current = widget.currentBranch;

    final branches = ref.watch(branchesProvider(widget.repoPath)).value;
    final remotes = ref.watch(remotesProvider(widget.repoPath)).value;
    final host = ref.watch(remoteHostProvider(widget.repoPath)).value;
    final canPush = remotes != null && remotes.isNotEmpty;
    final place = host != null && host.kind != RemoteHostKind.localFolder
        ? host.label
        : (remotes?.contains('origin') ?? false)
        ? 'origin'
        : remotes?.firstOrNull ?? 'online';

    final local = branches?.local ?? [if (current != null) current];
    final remoteOnly = branches?.remoteOnly ?? const <String>[];
    final isRemoteOnly = remoteOnly.contains(_from);
    final fromLabel = _from.isEmpty ? 'where you are now' : '“$_from”';

    final entries = [
      if (current == null)
        const DropdownMenuEntry(value: '', label: 'Where you are now'),
      for (final b in local)
        DropdownMenuEntry(
          value: b,
          label: b,
          leadingIcon: const Icon(Icons.call_split_rounded, size: 18),
          trailingIcon: _entryTrailing(
            b,
            label: b == current ? 'current' : null,
          ),
        ),
      for (final b in remoteOnly)
        DropdownMenuEntry(
          value: b,
          label: b,
          leadingIcon: const Icon(Icons.cloud_outlined, size: 18),
          trailingIcon: _entryTrailing(b, label: 'online only'),
        ),
    ];

    return AlertDialog(
      title: const Text('Create a new branch'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A branch is a safe space to try things without touching '
              'your other work.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              focusNode: _nameFocus,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Branch name',
                hintText: 'feature/login-screen',
                helperText:
                    normalized.isNotEmpty && normalized != _name.text.trim()
                    ? 'Will be created as “$normalized”'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(canPush: canPush),
            ),
            const SizedBox(height: 16),
            DropdownMenu<String>(
              // Re-created once the full branch list arrives.
              key: ValueKey(entries.length),
              initialSelection: _from,
              dropdownMenuEntries: entries,
              enableFilter: true,
              requestFocusOnTap: true,
              expandedInsets: EdgeInsets.zero,
              menuHeight: 320,
              label: const Text('Start from'),
              leadingIcon: const Icon(Icons.account_tree_outlined, size: 18),
              onSelected: (v) {
                if (v != null) setState(() => _from = v);
              },
            ),
            const SizedBox(height: 6),
            Text(
              isRemoteOnly
                  ? 'Starts from the online copy of “$_from”.'
                  : _from.isNotEmpty && _from != current && current != null
                  ? 'Starts from “$_from”. “$current” isn’t touched.'
                  : 'Starts from $fromLabel, with the same commits.',
              style: muted,
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _switch,
              onChanged: (v) => setState(() => _switch = v ?? true),
              title: const Text('Switch to it now'),
              subtitle: Text(
                _switch
                    ? _from.isNotEmpty && _from != current
                          ? 'Your files change to $fromLabel’s version. '
                                'Uncommitted edits come along.'
                          : 'Your files stay exactly as they are.'
                    : 'You stay on ${current == null ? 'where you are' : '“$current”'}.',
                style: muted,
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _push && canPush,
              onChanged: canPush
                  ? (v) => setState(() => _push = v ?? false)
                  : null,
              title: Text('Push it to $place'),
              subtitle: Text(
                !canPush
                    ? 'This repository isn’t connected online yet.'
                    : 'Creates it on $place too, so it’s backed up and '
                          'others can see it.',
                style: muted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: normalized.isEmpty
              ? null
              : () => _submit(canPush: canPush),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Asks for a new name for [branch]. Returns (new name, also rename online)
/// or null when cancelled. [online] is where it's published (e.g.
/// "GitHub"), or null when it isn't online.
Future<(String, bool)?> showRenameBranchDialog(
  BuildContext context, {
  required String branch,
  String? online,
}) => showDialog<(String, bool)>(
  context: context,
  builder: (_) => _RenameBranchDialog(branch: branch, online: online),
);

class _RenameBranchDialog extends StatefulWidget {
  const _RenameBranchDialog({required this.branch, this.online});

  final String branch;
  final String? online;

  @override
  State<_RenameBranchDialog> createState() => _RenameBranchDialogState();
}

class _RenameBranchDialogState extends State<_RenameBranchDialog> {
  late final _name = TextEditingController(text: widget.branch)
    ..selection = TextSelection(
      // Select the part after the last "/" (feature/<this>), the bit that
      // usually changes.
      baseOffset: widget.branch.lastIndexOf('/') + 1,
      extentOffset: widget.branch.length,
    );
  late bool _online = widget.online != null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _normalized => _NewBranchDialogState.normalize(_name.text);

  bool get _valid => _normalized.isNotEmpty && _normalized != widget.branch;

  void _submit() {
    if (_valid) Navigator.pop(context, (_normalized, _online));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final online = widget.online;
    return AlertDialog(
      title: Text('Rename “${widget.branch}”'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'New name',
                helperText:
                    _normalized.isNotEmpty && _normalized != _name.text.trim()
                    ? 'Will be renamed to “$_normalized”'
                    : 'Only the name changes — commits and files stay as they are.',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            if (online != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _online,
                onChanged: (v) => setState(() => _online = v ?? false),
                title: Text('Rename it on $online too'),
                subtitle: Text(
                  _online
                      ? 'Pushes the new name and removes the old one. An open '
                            'pull request for the old name will close, and '
                            'teammates need to switch to the new name.'
                      : 'Only on this computer. The online copy keeps the old '
                            'name (and stays linked).',
                  style: muted,
                ),
              )
            else
              Text('It isn’t online yet, so only this computer changes.', style: muted),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid ? _submit : null,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// Lists local and online branches (fast: a plain list, most recent first)
/// and returns the chosen name. The family tree is drawn only on request —
/// working it out takes a while on big repositories.
Future<String?> showSwitchBranchDialog(
  BuildContext context, {
  required String repoPath,
  required RepoStatus status,
  Future<void> Function(BranchSummary branch)? onRename,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SwitchBranchDialog(
      repoPath: repoPath,
      status: status,
      onRename: onRename,
    ),
  );
}

class _SwitchBranchDialog extends ConsumerStatefulWidget {
  const _SwitchBranchDialog({
    required this.repoPath,
    required this.status,
    this.onRename,
  });

  final String repoPath;
  final RepoStatus status;
  final Future<void> Function(BranchSummary branch)? onRename;

  @override
  ConsumerState<_SwitchBranchDialog> createState() =>
      _SwitchBranchDialogState();
}

class _SwitchBranchDialogState extends ConsumerState<_SwitchBranchDialog> {
  String _query = '';

  /// List (fast, default) or the family tree (slower, on request).
  bool _tree = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Switch branch')),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.list_rounded, size: 18),
                label: Text('List'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.account_tree_outlined, size: 18),
                label: Text('Tree'),
                tooltip: 'Draw where each branch grew from (slower)',
              ),
            ],
            selected: {_tree},
            onSelectionChanged: (v) => setState(() => _tree = v.first),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.status.isClean)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'You have uncommitted changes. They’ll come with you — unless they clash with the other '
                  'branch, in which case Gitty offers to put them aside first.',
                  style: TextStyle(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
            if (_tree) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.park_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your project is like a tree. The trunk is the main version, '
                      'and every branch grew out of another one — follow the lines '
                      'to see where each came from. Tap a branch to hop onto it.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Filter branches',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(child: _tree ? _buildTree() : _buildList()),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildTree() {
    final tree = ref.watch(branchTreeProvider(widget.repoPath));
    return tree.when(
      loading: () => const LoadingView(message: 'Drawing your branch tree…'),
      error: (e, _) => ErrorView(
        error: e,
        onRetry: () => ref.invalidate(branchTreeProvider(widget.repoPath)),
      ),
      data: (t) => t.nodes.isEmpty
          ? const Center(
              child: Text(
                'No branches yet — make your first commit and one appears.',
              ),
            )
          : BranchTreeView(
              tree: t,
              query: _query,
              onPick: (node) => Navigator.pop(context, node.name),
            ),
    );
  }

  Widget _buildList() {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final list = ref.watch(branchSummariesProvider(widget.repoPath));
    final current = widget.status.branch;
    return list.when(
      skipLoadingOnReload: true,
      loading: () => const LoadingView(message: 'Listing branches…'),
      error: (e, _) => ErrorView(
        error: e,
        onRetry: () =>
            ref.invalidate(branchSummariesProvider(widget.repoPath)),
      ),
      data: (all) {
        final q = _query.trim().toLowerCase();
        final shown = q.isEmpty
            ? all
            : all.where((b) => b.name.toLowerCase().contains(q)).toList();
        final local = shown.where((b) => !b.remoteOnly).toList();
        final online = shown.where((b) => b.remoteOnly).toList();
        if (shown.isEmpty) {
          return Center(
            child: Text(
              all.isEmpty
                  ? 'No branches yet — make your first commit and one appears.'
                  : 'No branch matches “${_query.trim()}”.',
              style: muted,
            ),
          );
        }
        Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
          child: Text(
            text.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.8),
          ),
        );
        return ListView(
          children: [
            if (local.isNotEmpty) header('On this computer'),
            for (final b in local)
              _BranchRow(
                branch: b,
                isCurrent: b.name == current,
                onPick: () => Navigator.pop(context, b.name),
                onRename: widget.onRename == null
                    ? null
                    : () async {
                        await widget.onRename!(b);
                        if (mounted) {
                          ref.invalidate(
                            branchSummariesProvider(widget.repoPath),
                          );
                        }
                      },
              ),
            if (online.isNotEmpty) header('Only online'),
            for (final b in online)
              _BranchRow(
                branch: b,
                isCurrent: false,
                onPick: () => Navigator.pop(context, b.name),
              ),
          ],
        );
      },
    );
  }
}

class _BranchRow extends StatefulWidget {
  const _BranchRow({
    required this.branch,
    required this.isCurrent,
    required this.onPick,
    this.onRename,
  });

  final BranchSummary branch;
  final bool isCurrent;
  final VoidCallback onPick;
  final VoidCallback? onRename;

  @override
  State<_BranchRow> createState() => _BranchRowState();
}

class _BranchRowState extends State<_BranchRow> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final b = widget.branch;
    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selected: widget.isCurrent,
      leading: Icon(
        widget.isCurrent
            ? Icons.check_circle_rounded
            : b.remoteOnly
            ? Icons.cloud_outlined
            : Icons.call_split_rounded,
        size: 18,
      ),
      title: Row(
        children: [
          Flexible(child: Text(b.name, overflow: TextOverflow.ellipsis)),
          if (widget.isCurrent) ...[
            const SizedBox(width: 8),
            Text(
              'you’re here',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.primary,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        [
          if (b.subject.isNotEmpty) '“${b.subject}”',
          timeAgo(b.lastCommit),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _copied ? 'Copied' : 'Copy name',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: b.name));
              if (!mounted) return;
              setState(() => _copied = true);
              await Future<void>.delayed(const Duration(milliseconds: 1200));
              if (mounted) setState(() => _copied = false);
            },
          ),
          if (widget.onRename != null)
            IconButton(
              tooltip: 'Rename',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: const Icon(Icons.drive_file_rename_outline_rounded),
              onPressed: widget.onRename,
            ),
        ],
      ),
      onTap: widget.isCurrent ? null : widget.onPick,
    );
  }
}

/// "Pull from another branch": pick a branch (search as you type), see how
/// much would come in, choose merge or rebase. Returns (branch, use its
/// online version, rebase) or null when cancelled.
Future<(String, bool, bool)?> showPullFromBranchDialog(
  BuildContext context, {
  required String repoPath,
  required RepoStatus status,
}) => showDialog<(String, bool, bool)>(
  context: context,
  builder: (_) => _PullFromBranchDialog(repoPath: repoPath, status: status),
);

class _PullFromBranchDialog extends ConsumerStatefulWidget {
  const _PullFromBranchDialog({required this.repoPath, required this.status});

  final String repoPath;
  final RepoStatus status;

  @override
  ConsumerState<_PullFromBranchDialog> createState() =>
      _PullFromBranchDialogState();
}

class _PullFromBranchDialogState extends ConsumerState<_PullFromBranchDialog> {
  String? _branch;
  bool _online = true;
  bool _rebase = false;
  Set<String> _onlineNames = const {};
  int? _incoming; // commits that would come in (as of the last download)
  bool _counting = false;

  String? get _current => widget.status.branch;

  @override
  void initState() {
    super.initState();
    _pickDefault();
  }

  /// Starts with where this branch grew from, else the main branch.
  Future<void> _pickDefault() async {
    final git = ref.read(gitServiceProvider);
    final online = (await git.remoteBranchNames(widget.repoPath)).toSet();
    final current = _current;
    final parent = current == null
        ? null
        : await git.recordedParent(widget.repoPath, current);
    final main = await git.remoteDefaultBranch(widget.repoPath) ??
        (online.contains('main')
            ? 'main'
            : online.contains('master')
            ? 'master'
            : null);
    if (!mounted) return;
    setState(() {
      _onlineNames = online;
      _branch ??= (parent != null && parent != current)
          ? parent
          : (main != null && main != current ? main : null);
    });
    _count();
  }

  bool _isOnline(String b) => _onlineNames.contains(b);

  String _ref(String b) => _online && _isOnline(b) ? 'origin/$b' : b;

  Future<void> _count() async {
    final b = _branch;
    if (b == null) return;
    setState(() => _counting = true);
    final n = await ref
        .read(gitServiceProvider)
        .commitsMissingFrom(widget.repoPath, _ref(b));
    if (mounted && b == _branch) {
      setState(() {
        _incoming = n;
        _counting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final current = _current ?? 'your branch';
    final list =
        ref.watch(branchSummariesProvider(widget.repoPath)).value ?? const [];
    final choices = list.where((b) => b.name != _current).toList();
    final branch = _branch;
    final canOnline = branch != null && _isOnline(branch);
    final localOnly = branch != null && !_isOnline(branch);
    final remoteOnly =
        branch != null && choices.any((b) => b.name == branch && b.remoteOnly);

    return AlertDialog(
      title: const Text('Pull from another branch'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Brings the latest changes of the branch you pick into '
              '“$current”. Your own work stays — nothing is thrown away.',
              style: muted,
            ),
            const SizedBox(height: 18),
            DropdownMenu<String>(
              key: ValueKey('${choices.length}-$branch'),
              initialSelection: branch,
              dropdownMenuEntries: [
                for (final b in choices)
                  DropdownMenuEntry(
                    value: b.name,
                    label: b.name,
                    leadingIcon: Icon(
                      b.remoteOnly
                          ? Icons.cloud_outlined
                          : Icons.call_split_rounded,
                      size: 18,
                    ),
                    trailingIcon: Text(
                      timeAgo(b.lastCommit),
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
              ],
              enableFilter: true,
              requestFocusOnTap: true,
              expandedInsets: EdgeInsets.zero,
              menuHeight: 320,
              label: const Text('Pull from'),
              hintText: 'Type to search branches',
              leadingIcon: const Icon(Icons.call_merge_rounded, size: 18),
              onSelected: (v) {
                if (v == null || v == _branch) return;
                setState(() {
                  _branch = v;
                  _incoming = null;
                });
                _count();
              },
            ),
            const SizedBox(height: 8),
            if (branch != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  _counting || _incoming == null
                      ? 'Checking what’s new…'
                      : _incoming == 0
                      ? (canOnline && _online
                            ? 'Nothing new as of the last check — Gitty will '
                                  'look online again when you pull.'
                            : '“$current” already has everything from “$branch”.')
                      : '${_incoming == 1 ? '1 new commit' : '$_incoming new commits'} '
                            'from “$branch” will come into “$current”'
                            '${canOnline && _online ? ' (maybe more — Gitty checks online first)' : ''}.',
                  style: muted,
                ),
              ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: canOnline && (_online || remoteOnly),
              onChanged: !canOnline || remoteOnly
                  ? null
                  : (v) {
                      setState(() => _online = v ?? true);
                      _count();
                    },
              title: const Text('Use its latest online version'),
              subtitle: Text(
                localOnly
                    ? 'This branch is only on this computer, so its local '
                          'version is used.'
                    : 'Downloads the newest commits of the branch first — '
                          'usually what you want.',
                style: muted,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.merge_rounded, size: 18),
                  label: Text('Merge (recommended)'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.low_priority_rounded, size: 18),
                  label: Text('Rebase'),
                ),
              ],
              selected: {_rebase},
              onSelectionChanged: (v) => setState(() => _rebase = v.first),
            ),
            const SizedBox(height: 8),
            Text(
              _rebase
                  ? 'Puts your commits on top of theirs, for a straight-line '
                        'history.${widget.status.upstream != null ? ' Your branch is already online, so you’d have to force-push afterwards — merge is safer.' : ''}'
                  : 'Joins both with one merge commit. Nothing is rewritten — '
                        'the safest choice.',
              style: _rebase && widget.status.upstream != null
                  ? theme.textTheme.bodySmall?.copyWith(color: scheme.error)
                  : muted,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: branch == null
              ? null
              : () => Navigator.pop(context, (
                  branch,
                  canOnline && (_online || remoteOnly),
                  _rebase,
                )),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Pull'),
        ),
      ],
    );
  }
}
