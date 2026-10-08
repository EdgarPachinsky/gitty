import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/gitty_exception.dart';
import '../../../core/utils/time_ago.dart';
import '../../../core/widgets/state_views.dart';
import '../../../services/ai/ai_text.dart';
import '../../../services/ai/change_prompts.dart';
import '../../../services/git/git_models.dart';
import '../../../services/git/workflow_models.dart';
import '../../../services/service_providers.dart';
import '../repo_actions_controller.dart';

/// Runs an action and shows its outcome (the repository screen's `_report`).
typedef ReportAction = Future<bool> Function(Future<ActionOutcome> Function());

/// Files in one shelf entry. (repository path, entry id)
final stashFilesProvider = FutureProvider.autoDispose
    .family<List<NameStatus>, (String, String)>(
      (ref, arg) => ref.watch(gitServiceProvider).stashFiles(arg.$1, arg.$2),
    );

/// Asks the AI for a short name for a set of changes.
Future<String> suggestShelfName(
  WidgetRef ref, {
  required String diff,
  required List<String> files,
  String? branch,
}) async {
  final ai = ref.read(aiTextProvider);
  final (system, prompt) = shelfNamePrompt(
    diff: ai.prepareDiff(diff),
    files: files,
    branch: branch,
  );
  final raw = await ai.complete(system: system, prompt: prompt);
  final line = plainText(raw).split('\n').first.trim();
  return line.length > 80 ? line.substring(0, 80) : line;
}

// --- "Put changes aside" dialog ------------------------------------------------------

/// Asks for a name (the AI suggests one from the changes) and returns it,
/// or null when cancelled. [reason] explains why it's being offered, e.g.
/// "Switching to dev needs a clean slate."
Future<String?> showPutAsideDialog(
  BuildContext context, {
  required String repoPath,
  required RepoStatus status,
  String? reason,
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _PutAsideDialog(repoPath: repoPath, status: status, reason: reason),
);

class _PutAsideDialog extends ConsumerStatefulWidget {
  const _PutAsideDialog({
    required this.repoPath,
    required this.status,
    this.reason,
  });

  final String repoPath;
  final RepoStatus status;
  final String? reason;

  @override
  ConsumerState<_PutAsideDialog> createState() => _PutAsideDialogState();
}

class _PutAsideDialogState extends ConsumerState<_PutAsideDialog> {
  late final _name = TextEditingController(text: _fallbackName());
  bool _writing = false;
  bool _typed = false;
  String? _aiNote;

  String _fallbackName() {
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return 'Work in progress on ${widget.status.branch ?? 'this commit'} ($time)';
  }

  @override
  void initState() {
    super.initState();
    if (ref.read(aiTextProvider).unavailableReason == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _suggest());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _suggest() async {
    if (_writing) return;
    setState(() {
      _writing = true;
      _aiNote = null;
    });
    try {
      final ai = ref.read(aiTextProvider);
      final diff = await ref
          .read(gitServiceProvider)
          .workingDiff(widget.repoPath, maxChars: ai.maxInputChars);
      final name = await suggestShelfName(
        ref,
        diff: diff,
        files: [for (final c in widget.status.changes) c.path],
        branch: widget.status.branch,
      );
      if (!mounted) return;
      if (!_typed && name.isNotEmpty) {
        _name.value = TextEditingValue(
          text: name,
          selection: TextSelection.collapsed(offset: name.length),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _aiNote = 'AI couldn’t suggest a name.');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final ai = ref.watch(aiTextProvider);
    final changes = widget.status.changes;

    return AlertDialog(
      title: const Text('Put changes aside'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.reason != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  widget.reason!,
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
              const SizedBox(height: 14),
            ],
            const Text(
              'Your uncommitted changes (new files too) go onto a shelf and '
              'your files go back to the last commit. Bring them back any '
              'time — nothing is lost.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              onChanged: (_) => _typed = true,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Name',
                helperText: _aiNote ??
                    (_writing
                        ? 'The AI is looking at your changes…'
                        : 'So you remember what this was.'),
                suffixIcon: ai.unavailableReason != null
                    ? null
                    : _writing
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: 'Name it with AI',
                        icon: const Icon(Icons.auto_awesome_outlined),
                        onPressed: () {
                          _typed = false;
                          _suggest();
                        },
                      ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${plural(changes.length, 'file')} will be put aside',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            for (final c in changes.take(6))
              Text('• ${c.path}', style: muted, overflow: TextOverflow.ellipsis),
            if (changes.length > 6)
              Text('• …and ${changes.length - 6} more', style: muted),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.inventory_2_outlined, size: 18),
          label: const Text('Put aside'),
        ),
      ],
    );
  }
}

// --- The shelf ---------------------------------------------------------------------------

/// "Put aside": unfinished work parked for later (Git's stash), with
/// friendly names. Hidden when there's nothing on it and nothing to park.
class ShelfCard extends ConsumerWidget {
  const ShelfCard({
    super.key,
    required this.repoPath,
    required this.status,
    required this.busy,
    required this.onPutAside,
    required this.report,
  });

  final String repoPath;
  final RepoStatus status;
  final bool busy;
  final VoidCallback onPutAside;
  final ReportAction report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final entries = ref.watch(stashesProvider(repoPath)).value ?? const [];
    if (entries.isEmpty && status.isClean) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('Put aside', style: theme.textTheme.titleMedium),
                if (entries.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${entries.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const Spacer(),
                if (!status.isClean)
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : onPutAside,
                    icon: const Icon(Icons.move_to_inbox_rounded, size: 18),
                    label: const Text('Put changes aside'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              entries.isEmpty
                  ? 'Need a clean slate for a moment? Park your unfinished '
                        'changes here and bring them back later.'
                  : 'Unfinished work waiting for you. Bring it back whenever '
                        'you’re ready.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (entries.isNotEmpty) const SizedBox(height: 8),
            for (final e in entries)
              _ShelfTile(
                repoPath: repoPath,
                entry: e,
                busy: busy,
                report: report,
              ),
          ],
        ),
      ),
      ),
    );
  }
}

class _ShelfTile extends ConsumerStatefulWidget {
  const _ShelfTile({
    required this.repoPath,
    required this.entry,
    required this.busy,
    required this.report,
  });

  final String repoPath;
  final StashEntry entry;
  final bool busy;
  final ReportAction report;

  @override
  ConsumerState<_ShelfTile> createState() => _ShelfTileState();
}

class _ShelfTileState extends ConsumerState<_ShelfTile> {
  bool _open = false;
  bool _naming = false;

  StashEntry get _e => widget.entry;

  RepoActionsController get _actions =>
      ref.read(repoActionsProvider(widget.repoPath).notifier);

  Future<void> _nameWithAi() async {
    setState(() => _naming = true);
    try {
      final git = ref.read(gitServiceProvider);
      final ai = ref.read(aiTextProvider);
      final diff = await git.stashDiff(
        widget.repoPath,
        _e.hash,
        maxChars: ai.maxInputChars,
      );
      final files = await git.stashFiles(widget.repoPath, _e.hash);
      final name = await suggestShelfName(
        ref,
        diff: diff,
        files: [for (final f in files) f.path],
        branch: _e.branch,
      );
      if (name.isEmpty) return;
      await widget.report(() => _actions.renameShelved(_e, name));
    } catch (e) {
      if (mounted) {
        final error = toGittyException(e);
        showFriendlySnack(context, message: error.message, error: error);
      }
    } finally {
      if (mounted) setState(() => _naming = false);
    }
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _e.message);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == _e.message) return;
    await widget.report(() => _actions.renameShelved(_e, name));
  }

  Future<void> _throwAway() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Throw these changes away?'),
        content: Text(
          '“${_e.message}” will be deleted for good. This can’t be undone '
          'from Gitty.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Throw away'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.report(() => _actions.dropShelved(_e));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final disabled = widget.busy || _naming;
    final ai = ref.watch(aiTextProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              children: [
                Icon(
                  _e.isGittyBackup
                      ? Icons.restore_page_outlined
                      : Icons.inventory_2_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _naming
                          ? Text(
                              'Naming it…',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontStyle: FontStyle.italic,
                              ),
                            )
                          : Text(
                              _e.message,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                      Text(
                        [
                          if (_e.branch != null) 'from ${_e.branch}',
                          timeAgo(_e.date),
                        ].join(' · '),
                        style: muted,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => widget.report(() => _actions.unshelve(_e)),
                  child: const Text('Bring back'),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  enabled: !disabled,
                  icon: const Icon(Icons.more_vert_rounded, size: 18),
                  onSelected: (v) => switch (v) {
                    'copy' => widget.report(
                      () => _actions.unshelve(_e, keepCopy: true),
                    ),
                    'rename' => _rename(),
                    'ai' => _nameWithAi(),
                    'drop' => _throwAway(),
                    _ => Future.value(),
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'copy',
                      child: Text('Bring back a copy (keep it here)'),
                    ),
                    const PopupMenuItem(value: 'rename', child: Text('Rename…')),
                    if (ai.unavailableReason == null)
                      const PopupMenuItem(
                        value: 'ai',
                        child: Text('Name it with AI'),
                      ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'drop',
                      child: Text('Throw away…'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 8),
            child: ref
                .watch(stashFilesProvider((widget.repoPath, _e.hash)))
                .when(
                  loading: () => const LinearProgressIndicator(minHeight: 2),
                  error: (e, _) => Text('Couldn’t list the files.', style: muted),
                  data: (files) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final f in files)
                        Text(
                          '${f.path}  ·  ${f.friendly}',
                          style: muted,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (files.isEmpty) Text('No files.', style: muted),
                    ],
                  ),
                ),
          ),
      ],
    );
  }
}
