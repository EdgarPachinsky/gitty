import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../errors/error_help_controller.dart';
import '../errors/gitty_exception.dart';

/// Friendly empty state: icon, title, message and optional actions.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 40,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Centered spinner with an optional reassuring message.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(
              message!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Friendly error with retry and expandable technical details.
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.error,
    this.onRetry,
    this.compact = false,
  });

  final Object error;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final e = toGittyException(error);
    final theme = Theme.of(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: compact
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.sentiment_dissatisfied_outlined,
              color: theme.colorScheme.error,
              size: 20,
            ),
            const SizedBox(width: 8),
            Flexible(child: Text(e.message, style: theme.textTheme.titleSmall)),
          ],
        ),
        if (e.hint != null) ...[
          const SizedBox(height: 6),
          Text(
            e.hint!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: compact ? TextAlign.start : TextAlign.center,
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            if (onRetry != null)
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
              ),
            if (e.details != null)
              TextButton(
                onPressed: () => showErrorDetails(context, e),
                child: const Text('Details'),
              ),
          ],
        ),
      ],
    );
    if (compact)
      return Padding(padding: const EdgeInsets.all(16), child: content);
    return Center(
      child: Padding(padding: const EdgeInsets.all(32), child: content),
    );
  }
}

/// Shows everything about [e]: in the side panel (with "Ask AI") when the
/// main window is up, otherwise in a dialog.
Future<void> showErrorDetails(BuildContext context, GittyException e) {
  if (openErrorHelp(context, e)) {
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    return Future.value();
  }
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(e.message),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 360),
        child: SingleChildScrollView(
          child: SelectableText(
            [
              if (e.hint != null) e.hint!,
              if (e.details != null) e.details!,
            ].join('\n\n'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Shows an [outcome]-style snackbar. Success is quiet and fades away.
/// Errors stay until closed and offer "See details" and "Ask AI", which
/// open the help side panel.
void showFriendlySnack(
  BuildContext context, {
  required String message,
  GittyException? error,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;

  // Captured now: the snackbar outlives e.g. the dialog that showed it.
  final panel = error != null && ErrorHelpController.hosts > 0
      ? ProviderScope.containerOf(context, listen: false)
      : null;
  void openPanel({required bool askAi}) {
    messenger.hideCurrentSnackBar();
    panel!.read(errorHelpProvider.notifier).open(error!, askAi: askAi);
  }

  final hasDetails = error?.details != null || error?.hint != null;
  final buttonStyle = TextButton.styleFrom(
    foregroundColor: scheme.inversePrimary,
    visualDensity: VisualDensity.compact,
  );

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        showCloseIcon: error != null,
        closeIconColor: scheme.onInverseSurface,
        content: Row(
          children: [
            Icon(
              error == null ? Icons.check_circle_outline : Icons.info_outline,
              color: error == null
                  ? scheme.inversePrimary
                  : scheme.errorContainer,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                error?.hint == null ? message : '$message ${error!.hint}',
              ),
            ),
            if (error != null && panel != null) ...[
              const SizedBox(width: 8),
              if (hasDetails)
                TextButton(
                  style: buttonStyle,
                  onPressed: () => openPanel(askAi: false),
                  child: const Text('See details'),
                ),
              TextButton.icon(
                style: buttonStyle,
                onPressed: () => openPanel(askAi: true),
                icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                label: const Text('Ask AI'),
              ),
            ] else if (error?.details != null)
              TextButton(
                style: buttonStyle,
                onPressed: () => showErrorDetails(context, error!),
                child: const Text('Details'),
              ),
          ],
        ),
        // Errors wait for you; successes fade quickly.
        duration: error == null
            ? const Duration(seconds: 3)
            : const Duration(days: 1),
      ),
    );
}
