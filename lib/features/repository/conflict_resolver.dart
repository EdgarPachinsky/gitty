import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/gitty_exception.dart';
import '../../core/utils/time_ago.dart';
import '../../core/widgets/state_views.dart';
import '../../services/ai/ai_text.dart';
import '../../services/ai/change_prompts.dart';
import '../../services/git/git_service.dart';
import '../../services/git/workflow_models.dart';
import '../../services/service_providers.dart';
import 'repo_actions_controller.dart';

/// Side-by-side conflict resolver: for every clash, keep yours, keep the
/// incoming version, keep both, or write your own — with the AI explaining
/// the two sides or suggesting a combination. Then finish (or cancel) the
/// merge/rebase in one click.
class ConflictResolverScreen extends ConsumerStatefulWidget {
  const ConflictResolverScreen({super.key, required this.repoPath});

  final String repoPath;

  static Future<void> open(BuildContext context, String repoPath) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConflictResolverScreen(repoPath: repoPath),
        ),
      );

  @override
  ConsumerState<ConflictResolverScreen> createState() =>
      _ConflictResolverScreenState();
}

class _ConflictResolverScreenState
    extends ConsumerState<ConflictResolverScreen> {
  String? _selected;

  RepoActionsController get _actions =>
      ref.read(repoActionsProvider(widget.repoPath).notifier);

  Future<bool> _step(Future<String> Function(GitService git) body) async {
    final outcome = await _actions.resolveStep(body);
    if (mounted) {
      showFriendlySnack(context, message: outcome.message, error: outcome.error);
    }
    return outcome.ok;
  }

  Future<void> _finish(ConflictState state) async {
    final ok = await _step((git) async {
      await git.continueOperation(widget.repoPath, state.operation);
      return switch (state.operation) {
        ConflictOperation.merge => 'Merge finished — nicely done!',
        ConflictOperation.rebase => 'Rebase continued.',
        _ => 'All done.',
      };
    });
    if (!ok || !mounted) return;
    // A rebase can stop again on the next commit; stay if there's more.
    final next = await ref.refresh(conflictStateProvider(widget.repoPath).future);
    if (mounted && next.files.isEmpty && next.finishLabel == null) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _cancel(ConflictState state) async {
    final label = state.cancelLabel;
    if (label == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label?'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'Everything goes back to exactly how it was before it started, '
            'including the choices you made here.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(label),
          ),
        ],
      ),
    );
    if (sure != true) return;
    final ok = await _step((git) async {
      await git.abortOperation(widget.repoPath, state.operation);
      return 'Cancelled — everything is back to how it was.';
    });
    if (ok && mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(conflictStateProvider(widget.repoPath));
    final busy = ref.watch(repoActionsProvider(widget.repoPath)) != null;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Resolve conflicts'),
            if (state.value != null)
              Text(
                state.value!.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          if (state.value?.cancelLabel != null)
            TextButton(
              onPressed: busy ? null : () => _cancel(state.value!),
              child: Text(state.value!.cancelLabel!),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: state.when(
        skipLoadingOnReload: true,
        loading: () => const LoadingView(message: 'Looking at the clashes…'),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(conflictStateProvider(widget.repoPath)),
        ),
        data: (s) {
          if (s.files.isEmpty) return _AllDone(state: s, busy: busy, onFinish: () => _finish(s));
          final selected = s.files
                  .where((f) => f.path == _selected)
                  .firstOrNull ??
              s.files.first;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 280,
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                      child: Text(
                        '${plural(s.files.length, 'file')} to sort out',
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    for (final f in s.files)
                      ListTile(
                        dense: true,
                        selected: f.path == selected.path,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        leading: Icon(
                          f.isDeleteConflict
                              ? Icons.delete_sweep_outlined
                              : Icons.call_merge_rounded,
                          size: 18,
                        ),
                        title: Text(
                          p.basename(f.path),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          p.dirname(f.path) == '.' ? '' : p.dirname(f.path),
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => setState(() => _selected = f.path),
                      ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: _FileResolver(
                  key: ValueKey(selected.path),
                  repoPath: widget.repoPath,
                  file: selected,
                  state: s,
                  busy: busy,
                  onStep: _step,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AllDone extends StatelessWidget {
  const _AllDone({
    required this.state,
    required this.busy,
    required this.onFinish,
  });

  final ConflictState state;
  final bool busy;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final finish = state.finishLabel;
    return EmptyState(
      icon: Icons.task_alt_rounded,
      title: 'All clashes are sorted out',
      message: finish == null
          ? 'Your files are ready. Commit whenever you like.'
          : 'One last step: ${finish.toLowerCase()} to wrap it up.',
      actions: [
        if (finish != null)
          FilledButton.icon(
            onPressed: busy ? null : onFinish,
            icon: const Icon(Icons.check_rounded),
            label: Text(finish),
          )
        else
          FilledButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Back to the repository'),
          ),
      ],
    );
  }
}

// --- One file ---------------------------------------------------------------------

enum _Pick { ours, theirs, both, custom }

class _FileResolver extends ConsumerStatefulWidget {
  const _FileResolver({
    super.key,
    required this.repoPath,
    required this.file,
    required this.state,
    required this.busy,
    required this.onStep,
  });

  final String repoPath;
  final ConflictFile file;
  final ConflictState state;
  final bool busy;
  final Future<bool> Function(Future<String> Function(GitService git)) onStep;

  @override
  ConsumerState<_FileResolver> createState() => _FileResolverState();
}

class _FileResolverState extends ConsumerState<_FileResolver> {
  late final Future<List<ConflictSegment>?> _load = _read();
  final _picks = <int, _Pick>{};
  final _custom = <int, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _custom.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Null when the file can't be shown as text (binary, or deleted on one
  /// side) — then only whole-file choices are offered.
  Future<List<ConflictSegment>?> _read() async {
    if (widget.file.isDeleteConflict) return null;
    try {
      final bytes = await File(p.join(widget.repoPath, widget.file.path)).readAsBytes();
      if (bytes.take(8000).contains(0)) return null; // binary
      final segments = parseConflictMarkers(
        utf8.decode(bytes, allowMalformed: true),
      );
      return segments.any((s) => s is ClashSegment) ? segments : null;
    } catch (_) {
      return null;
    }
  }

  TextEditingController _editorFor(int i, ClashSegment c) => _custom.putIfAbsent(
    i,
    () => TextEditingController(text: '${c.ours}${c.theirs}'),
  );

  String _build(List<ConflictSegment> segments) {
    final out = StringBuffer();
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      switch (s) {
        case PlainSegment(:final text):
          out.write(text);
        case final ClashSegment c:
          switch (_picks[i]!) {
            case _Pick.ours:
              out.write(c.ours);
            case _Pick.theirs:
              out.write(c.theirs);
            case _Pick.both:
              out.write('${c.ours}${c.theirs}');
            case _Pick.custom:
              var text = _custom[i]!.text;
              if (text.isNotEmpty && !text.endsWith('\n')) text = '$text\n';
              out.write(text);
          }
      }
    }
    return out.toString();
  }

  Future<void> _takeSide({required bool ours}) async {
    final (oursName, theirsName) = widget.state.sideNames;
    await widget.onStep((git) async {
      await git.takeSide(widget.repoPath, widget.file.path, ours: ours);
      return 'Kept “${ours ? oursName : theirsName}” for ${p.basename(widget.file.path)}.';
    });
  }

  Future<void> _save(List<ConflictSegment> segments) async {
    final text = _build(segments);
    await widget.onStep((git) async {
      await git.saveResolved(widget.repoPath, widget.file.path, text);
      return 'Saved ${p.basename(widget.file.path)} — clash resolved.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (oursName, theirsName) = widget.state.sideNames;

    return FutureBuilder<List<ConflictSegment>?>(
      future: _load,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const LoadingView();
        }
        final segments = snap.data;
        final header = Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.file.path,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!widget.file.isDeleteConflict) ...[
                OutlinedButton(
                  onPressed: widget.busy ? null : () => _takeSide(ours: true),
                  child: Text('Keep all: $oursName'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: widget.busy ? null : () => _takeSide(ours: false),
                  child: Text('Keep all: $theirsName'),
                ),
              ],
            ],
          ),
        );

        if (segments == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(child: _WholeFileChoice(parent: this)),
            ],
          );
        }

        final clashes = <int>[
          for (var i = 0; i < segments.length; i++)
            if (segments[i] is ClashSegment) i,
        ];
        final decided = clashes.where(_picks.containsKey).length;
        final allDecided = decided == clashes.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                '${plural(clashes.length, 'clash', 'clashes')} · $decided decided',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                children: [
                  for (var i = 0; i < segments.length; i++)
                    switch (segments[i]) {
                      PlainSegment(:final text) => _PlainText(text: text),
                      final ClashSegment c => _ClashCard(
                        key: ValueKey(i),
                        number: clashes.indexOf(i) + 1,
                        total: clashes.length,
                        clash: c,
                        path: widget.file.path,
                        oursName: oursName,
                        theirsName: theirsName,
                        pick: _picks[i],
                        editor: _picks[i] == _Pick.custom
                            ? _editorFor(i, c)
                            : null,
                        onPick: (pick) => setState(() {
                          if (pick == _Pick.custom) _editorFor(i, c);
                          _picks[i] = pick;
                        }),
                        onSuggested: (text) => setState(() {
                          _editorFor(i, c).text = text;
                          _picks[i] = _Pick.custom;
                        }),
                      ),
                    },
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      allDecided
                          ? 'Everything decided. Save to mark this file as sorted out.'
                          : 'Pick what to keep for every clash, then save.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: allDecided && !widget.busy
                        ? () => _save(segments)
                        : null,
                    icon: const Icon(Icons.save_rounded, size: 18),
                    label: const Text('Save and mark as resolved'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// For binary files and "one side deleted it" clashes.
class _WholeFileChoice extends StatelessWidget {
  const _WholeFileChoice({required this.parent});

  final _FileResolverState parent;

  @override
  Widget build(BuildContext context) {
    final w = parent.widget;
    final (oursName, theirsName) = w.state.sideNames;
    final f = w.file;
    if (f.isDeleteConflict) {
      final deleter = f.inOurs ? theirsName : oursName;
      final changer = f.inOurs ? oursName : theirsName;
      return EmptyState(
        icon: Icons.delete_sweep_outlined,
        title: '“$deleter” deleted this file, “$changer” changed it',
        message: 'Keep the file (with the changes), or let it go?',
        actions: [
          FilledButton(
            onPressed: w.busy
                ? null
                : () => w.onStep((git) async {
                    await git.keepOrDelete(w.repoPath, f.path, keep: true);
                    return 'Kept ${p.basename(f.path)}.';
                  }),
            child: const Text('Keep the file'),
          ),
          OutlinedButton(
            onPressed: w.busy
                ? null
                : () => w.onStep((git) async {
                    await git.keepOrDelete(w.repoPath, f.path, keep: false);
                    return 'Removed ${p.basename(f.path)}.';
                  }),
            child: const Text('Delete the file'),
          ),
        ],
      );
    }
    return EmptyState(
      icon: Icons.insert_drive_file_outlined,
      title: 'This file can’t be compared line by line',
      message: 'It’s not a text file (or has no clash markers). Pick which '
          'version to keep as a whole.',
      actions: [
        FilledButton(
          onPressed: w.busy ? null : () => parent._takeSide(ours: true),
          child: Text('Keep: $oursName'),
        ),
        OutlinedButton(
          onPressed: w.busy ? null : () => parent._takeSide(ours: false),
          child: Text('Keep: $theirsName'),
        ),
      ],
    );
  }
}

/// Unchanged text between clashes; long stretches are folded.
class _PlainText extends StatefulWidget {
  const _PlainText({required this.text});

  final String text;

  @override
  State<_PlainText> createState() => _PlainTextState();
}

class _PlainTextState extends State<_PlainText> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: theme.colorScheme.onSurfaceVariant,
    );
    var lines = widget.text.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines = lines.sublist(0, lines.length - 1);
    if (lines.isEmpty) return const SizedBox.shrink();
    if (_open || lines.length <= 8) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SelectableText(lines.join('\n'), style: style),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(lines.take(3).join('\n'), style: style),
          TextButton.icon(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => setState(() => _open = true),
            icon: const Icon(Icons.unfold_more_rounded, size: 16),
            label: Text('${lines.length - 6} unchanged lines'),
          ),
          SelectableText(lines.skip(lines.length - 3).join('\n'), style: style),
        ],
      ),
    );
  }
}

class _ClashCard extends ConsumerStatefulWidget {
  const _ClashCard({
    super.key,
    required this.number,
    required this.total,
    required this.clash,
    required this.path,
    required this.oursName,
    required this.theirsName,
    required this.pick,
    required this.editor,
    required this.onPick,
    required this.onSuggested,
  });

  final int number;
  final int total;
  final ClashSegment clash;
  final String path;
  final String oursName;
  final String theirsName;
  final _Pick? pick;
  final TextEditingController? editor;
  final ValueChanged<_Pick> onPick;
  final ValueChanged<String> onSuggested;

  @override
  ConsumerState<_ClashCard> createState() => _ClashCardState();
}

class _ClashCardState extends ConsumerState<_ClashCard> {
  String? _explanation;
  bool _explaining = false;
  bool _suggesting = false;
  String? _aiError;

  static String _cap(String s) =>
      s.length > 4000 ? '${s.substring(0, 4000)}\n…' : s;

  Future<void> _explain() async {
    setState(() {
      _explaining = true;
      _aiError = null;
    });
    try {
      final c = widget.clash;
      final (system, prompt) = conflictExplainPrompt(
        path: widget.path,
        oursName: widget.oursName,
        theirsName: widget.theirsName,
        ours: _cap(c.ours),
        theirs: _cap(c.theirs),
        base: c.base == null ? null : _cap(c.base!),
      );
      final text = await ref.read(aiTextProvider).complete(
        system: system,
        prompt: prompt,
        onText: (t) {
          if (mounted) setState(() => _explanation = plainText(t));
        },
      );
      if (mounted) setState(() => _explanation = plainText(text));
    } catch (e) {
      if (mounted) setState(() => _aiError = toGittyException(e).message);
    } finally {
      if (mounted) setState(() => _explaining = false);
    }
  }

  Future<void> _suggest() async {
    setState(() {
      _suggesting = true;
      _aiError = null;
    });
    try {
      final c = widget.clash;
      final (system, prompt) = conflictMergePrompt(
        path: widget.path,
        ours: _cap(c.ours),
        theirs: _cap(c.theirs),
        base: c.base == null ? null : _cap(c.base!),
      );
      final text = await ref
          .read(aiTextProvider)
          .complete(system: system, prompt: prompt);
      if (mounted) widget.onSuggested(stripCodeFence(stripThinking(text)));
    } catch (e) {
      if (mounted) setState(() => _aiError = toGittyException(e).message);
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = widget.clash;
    final pick = widget.pick;
    final aiReady = ref.watch(aiTextProvider).unavailableReason == null;

    Widget side(String name, String text, bool chosen) => Expanded(
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: chosen ? scheme.primary : scheme.outlineVariant,
            width: chosen ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: chosen
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(9),
                ),
              ),
              child: Text(name, style: theme.textTheme.labelLarge),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10),
                child: SelectableText(
                  text.isEmpty ? '(nothing — removed here)' : text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontStyle: text.isEmpty ? FontStyle.italic : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.call_merge_rounded, size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Text(
                  'Clash ${widget.number} of ${widget.total}',
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                if (aiReady) ...[
                  TextButton.icon(
                    onPressed: _explaining ? null : _explain,
                    icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                    label: const Text('Explain'),
                  ),
                  TextButton.icon(
                    onPressed: _suggesting ? null : _suggest,
                    icon: _suggesting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high_outlined, size: 16),
                    label: const Text('Suggest a combination'),
                  ),
                ],
              ],
            ),
            if (_explanation != null || _explaining) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _explanation ?? 'Looking at both sides…',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
            if (_aiError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _aiError!,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final ours = side(
                  widget.oursName,
                  c.ours,
                  pick == _Pick.ours || pick == _Pick.both,
                );
                final theirs = side(
                  widget.theirsName,
                  c.theirs,
                  pick == _Pick.theirs || pick == _Pick.both,
                );
                return constraints.maxWidth >= 700
                    ? IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [ours, const SizedBox(width: 10), theirs],
                        ),
                      )
                    : Column(
                        children: [
                          Row(children: [ours]),
                          const SizedBox(height: 8),
                          Row(children: [theirs]),
                        ],
                      );
              },
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, label) in [
                  (_Pick.ours, 'Keep ${widget.oursName}'),
                  (_Pick.theirs, 'Keep ${widget.theirsName}'),
                  (_Pick.both, 'Keep both'),
                  (_Pick.custom, 'Write my own'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: pick == value,
                    onSelected: (_) => widget.onPick(value),
                  ),
              ],
            ),
            if (pick == _Pick.custom && widget.editor != null) ...[
              const SizedBox(height: 10),
              TextField(
                controller: widget.editor,
                minLines: 3,
                maxLines: max(3, min(16, widget.editor!.text.split('\n').length + 1)),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
                decoration: const InputDecoration(
                  labelText: 'What this part should say',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
