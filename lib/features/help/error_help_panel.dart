import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/error_help_controller.dart';
import '../../core/errors/gitty_exception.dart';
import '../../services/ai/error_help_service.dart';
import '../../services/service_providers.dart';
import '../account/account_controller.dart';
import '../dashboard/tracked_repos_controller.dart';

/// "Help with this error": the error first, then a plain-language AI
/// explanation with steps, then room for follow-up questions. Docked on
/// the right so the app stays usable while you follow the steps.
class ErrorHelpPanel extends ConsumerStatefulWidget {
  const ErrorHelpPanel({
    super.key,
    required this.request,
    required this.repoPath,
    required this.onClose,
  });

  final ErrorHelpRequest request;

  /// Repository open when the error happened (for context), if any.
  final String? repoPath;
  final VoidCallback onClose;

  @override
  ConsumerState<ErrorHelpPanel> createState() => _ErrorHelpPanelState();
}

class _ErrorHelpPanelState extends ConsumerState<ErrorHelpPanel> {
  final _turns = <HelpTurn>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _asking = false;
  String _partial = '';
  GittyException? _aiError;

  /// Question to repeat on "Try again" (null = the first explanation).
  String? _lastQuestion;

  GittyException get _error => widget.request.error;

  /// The repository at the moment the error happened (navigating away
  /// shouldn't change what the AI is told).
  late final String? _repoPath = widget.repoPath;

  @override
  void initState() {
    super.initState();
    if (widget.request.askAi) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  ErrorHelpContext _context() {
    final path = _repoPath;
    final status = path == null
        ? null
        : ref.read(repoSnapshotProvider(path)).value?.status;
    return ErrorHelpContext(
      error: _error,
      repoName: path == null ? null : p.basename(path),
      branch: status?.branch,
      upstream: status?.upstream,
      ahead: status?.ahead ?? 0,
      behind: status?.behind ?? 0,
      changeCount: status?.changes.length ?? 0,
      conflictCount: status?.conflictCount ?? 0,
      detached: status?.isDetached ?? false,
      githubAccount: ref.read(accountProvider).value?.username,
    );
  }

  Future<void> _ask([String? question]) async {
    if (_asking) return;
    final service = ref.read(errorHelpServiceProvider);
    if (service.unavailableReason != null) return;
    final history = List<HelpTurn>.of(_turns);
    setState(() {
      _asking = true;
      _partial = '';
      _aiError = null;
      _lastQuestion = question;
      if (question != null) _turns.add(HelpTurn(fromUser: true, text: question));
    });
    _scrollToEnd();
    try {
      final answer = await service.ask(
        _context(),
        history: history,
        question: question,
        onText: (text) {
          if (!mounted) return;
          setState(() => _partial = text);
          _scrollToEnd();
        },
      );
      if (!mounted) return;
      setState(() => _turns.add(HelpTurn(fromUser: false, text: answer)));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiError = toGittyException(e);
        // Keep the question in the box so it can be sent again.
        if (question != null) {
          _turns.removeLast();
          _input.text = question;
        }
      });
    } finally {
      if (mounted) setState(() => _asking = false);
      _scrollToEnd();
    }
  }

  void _send() {
    final q = _input.text.trim();
    if (q.isEmpty || _asking) return;
    _input.clear();
    _ask(q);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final service = ref.watch(errorHelpServiceProvider);
    final unavailable = service.unavailableReason;
    final started = _turns.isNotEmpty || _asking || _aiError != null;

    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
            child: Row(
              children: [
                Icon(Icons.support_agent, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Help with this error',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              children: [
                _ErrorCard(error: _error),
                const SizedBox(height: 20),
                _AiHeader(service: service),
                const SizedBox(height: 10),
                if (unavailable != null)
                  _Note(icon: Icons.info_outline, text: unavailable)
                else if (!started)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: () => _ask(),
                      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                      label: const Text('Ask AI what to do'),
                    ),
                  ),
                for (final turn in _turns) _Bubble(turn: turn),
                if (_asking)
                  _partial.isEmpty
                      ? const _Thinking()
                      : _Bubble(
                          turn: HelpTurn(fromUser: false, text: _partial),
                        ),
                if (_aiError != null) ...[
                  _Note(
                    icon: Icons.error_outline,
                    text: [
                      _aiError!.message,
                      if (_aiError!.hint != null) _aiError!.hint!,
                    ].join(' '),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _asking
                          ? null
                          : () {
                              final q = _lastQuestion;
                              if (q != null) _input.clear();
                              _ask(q);
                            },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Try again'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (unavailable == null && _turns.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Ask a follow-up…',
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Send',
                    onPressed: _asking ? null : _send,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The error itself, always on top: message, hint, and Git's raw output
/// folded away.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});

  final GittyException error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final details = error.details;
    return Container(
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  error.message,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
          if (error.hint != null)
            Padding(
              padding: const EdgeInsets.only(left: 30, top: 4),
              child: SelectableText(
                error.hint!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          if (details != null)
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.only(left: 22),
                childrenPadding: const EdgeInsets.only(bottom: 8),
                iconColor: scheme.onErrorContainer,
                collapsedIconColor: scheme.onErrorContainer,
                title: Text(
                  'Show Git’s exact output',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
                children: [
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 240),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Stack(
                      children: [
                        SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(10, 10, 36, 10),
                          child: SelectableText(
                            details,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: IconButton(
                            tooltip: 'Copy',
                            visualDensity: VisualDensity.compact,
                            iconSize: 16,
                            onPressed: () =>
                                Clipboard.setData(ClipboardData(text: details)),
                            icon: const Icon(Icons.copy_rounded),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else
            const SizedBox(height: 6),
        ],
      ),
    );
  }
}

/// "✦ AI · llama3.2 via Ollama · stays on this computer"
class _AiHeader extends StatelessWidget {
  const _AiHeader({required this.service});

  final ErrorHelpService service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.auto_awesome_rounded,
          size: 18,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ask AI', style: theme.textTheme.titleSmall),
              Text(
                service.unavailableReason != null
                    ? 'Not available right now'
                    : service.isLocal
                    ? 'Uses ${service.engineName} · stays on this computer'
                    : 'Uses ${service.engineName} · sends the error, Git’s '
                          'output and branch names — never your code',
                style: muted,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});

  final HelpTurn turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = turn.fromUser;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints: BoxConstraints(maxWidth: user ? 300 : double.infinity),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: user ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: user
              ? null
              : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: SelectableText(
          turn.text,
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.45,
            color: user ? scheme.onPrimaryContainer : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            'Looking into it…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
