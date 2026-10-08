import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/gitty_exception.dart';
import '../../../services/ai/ai_text.dart';
import '../../../services/ai/change_prompts.dart';
import '../../../services/git/git_models.dart';
import '../../../services/service_providers.dart';
import '../../dashboard/tracked_repos_controller.dart';

/// A short note above the changes list saying what you're in the middle of
/// — written by you, or by the AI from the actual changes (optionally kept
/// up to date automatically). Cleared once everything is committed.
class ChangesSummaryBox extends ConsumerStatefulWidget {
  const ChangesSummaryBox({
    super.key,
    required this.repoPath,
    required this.status,
    required this.onUseAsMessage,
  });

  final String repoPath;
  final RepoStatus status;

  /// Puts the summary into the commit message box.
  final ValueChanged<String> onUseAsMessage;

  @override
  ConsumerState<ChangesSummaryBox> createState() => _ChangesSummaryBoxState();
}

class _ChangesSummaryBoxState extends ConsumerState<ChangesSummaryBox> {
  final _edit = TextEditingController();
  bool _editing = false;
  bool _writing = false;
  String _partial = '';
  String? _error;
  Timer? _debounce;
  String? _seen; // changes fingerprint last looked at

  String get _path => widget.repoPath;

  @override
  void dispose() {
    _debounce?.cancel();
    _edit.dispose();
    super.dispose();
  }

  TrackedReposController get _repos =>
      ref.read(trackedReposProvider.notifier);

  String _fingerprint(RepoStatus s) => [
    s.headOid ?? '',
    for (final c in s.changes)
      '${c.path}:${c.kind.name}:${c.staged ? 1 : 0}${c.unstaged ? 1 : 0}',
  ].join('|');

  /// Keeps the summary in step with the changes (after the frame is drawn).
  void _react(String? summary, bool byAi, bool auto) {
    final fp = _fingerprint(widget.status);
    if (fp == _seen) return;
    final firstLook = _seen == null;
    _seen = fp;
    if (widget.status.isClean) {
      // Everything committed (or put aside): the note is done.
      if (summary != null) _repos.setChangesSummary(_path, null);
      return;
    }
    if (!auto || _editing) return;
    if (summary != null && !byAi) return; // never overwrite your own words
    if (firstLook && summary != null) return; // still fresh from last time
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () {
      if (mounted) _generate();
    });
  }

  Future<void> _generate() async {
    final ai = ref.read(aiTextProvider);
    if (ai.unavailableReason != null) {
      setState(() => _error = ai.unavailableReason);
      return;
    }
    if (_writing) return;
    setState(() {
      _writing = true;
      _partial = '';
      _error = null;
    });
    try {
      final diff = await ref
          .read(gitServiceProvider)
          .workingDiff(_path, maxChars: ai.maxInputChars);
      final changes = widget.status.changes;
      final (system, prompt) = changesSummaryPrompt(
        diff: ai.prepareDiff(diff),
        files: [
          for (final c in changes)
            if (!c.isUntracked) c.path,
        ],
        newFiles: [
          for (final c in changes)
            if (c.isUntracked) c.path,
        ],
        branch: widget.status.branch,
      );
      final text = await ai.complete(
        system: system,
        prompt: prompt,
        onText: (t) {
          if (mounted) setState(() => _partial = plainText(t));
        },
      );
      await _repos.setChangesSummary(_path, _tidy(text), byAi: true);
    } catch (e) {
      if (mounted) setState(() => _error = toGittyException(e).message);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  /// Plain bullet lines, at most six.
  static String _tidy(String raw) {
    final lines = plainText(raw)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map((l) => l.replaceFirst(RegExp(r'^([-*•]|\d+\.)\s*'), '• '))
        .take(6)
        .toList();
    return lines.join('\n');
  }

  /// "• a\n• b" → "a\n\n- b" (first line becomes the subject).
  static String _asCommitMessage(String summary) {
    final lines = summary
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^([-*•]|\d+\.)\s*'), '').trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    if (lines.length == 1) return lines.first;
    return '${lines.first}\n\n${lines.skip(1).map((l) => '- $l').join('\n')}';
  }

  void _startEditing(String? summary) {
    _edit.text = summary ?? '';
    setState(() => _editing = true);
  }

  Future<void> _save() async {
    await _repos.setChangesSummary(_path, _edit.text, byAi: false);
    if (mounted) setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref
        .watch(trackedReposProvider)
        .where((r) => r.path == _path)
        .firstOrNull;
    final summary = repo?.changesSummary;
    final byAi = repo?.changesSummaryByAi ?? false;
    final auto = repo?.autoSummary ?? false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _react(summary, byAi, auto);
    });
    if (widget.status.isClean) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final ai = ref.watch(aiTextProvider);
    final aiReady = ai.unavailableReason == null;

    Widget action(IconData icon, String tip, VoidCallback? onTap) =>
        IconButton(
          tooltip: tip,
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          visualDensity: VisualDensity.compact,
        );

    final Widget body;
    if (_editing) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _edit,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'What are you working on?',
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _editing = false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 6),
              FilledButton.tonal(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ],
      );
    } else if (_writing) {
      body = _partial.isEmpty
          ? Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('Reading your changes…', style: muted),
              ],
            )
          : Text(_partial, style: theme.textTheme.bodyMedium);
    } else if (summary != null) {
      body = SelectableText(
        summary,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
      );
    } else {
      body = Text(
        aiReady
            ? 'What are you in the middle of? Write a note, or let the AI '
                  'summarize your changes.'
            : 'What are you in the middle of? Write a short note to remember.',
        style: muted,
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 16, bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.notes_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text('Summary', style: theme.textTheme.labelLarge),
              if (summary != null && !_editing) ...[
                const SizedBox(width: 8),
                Text(byAi ? '✦ by AI' : 'by you', style: muted),
              ],
              const Spacer(),
              if (!_editing) ...[
                if (aiReady)
                  action(
                    Icons.auto_awesome_outlined,
                    summary == null ? 'Summarize with AI' : 'Rewrite with AI',
                    _writing ? null : _generate,
                  ),
                action(
                  Icons.edit_outlined,
                  summary == null ? 'Write it yourself' : 'Edit',
                  _writing ? null : () => _startEditing(summary),
                ),
                if (summary != null) ...[
                  action(
                    Icons.input_rounded,
                    'Use as commit message',
                    () => widget.onUseAsMessage(_asCommitMessage(summary)),
                  ),
                  action(
                    Icons.close_rounded,
                    'Clear',
                    () => _repos.setChangesSummary(_path, null),
                  ),
                ],
              ],
            ],
          ),
          const SizedBox(height: 6),
          Padding(padding: const EdgeInsets.only(right: 8), child: body),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 8),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          if (aiReady && !_editing) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: auto,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) {
                      _repos.setAutoSummary(_path, v ?? false);
                      // Turning it on with no summary yet: write one now.
                      if ((v ?? false) && summary == null) _generate();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Keep it updated with AI as you work'
                    '${ai.isLocal ? '' : ' (sends your changes to ${ai.engineName})'}',
                    style: muted,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
