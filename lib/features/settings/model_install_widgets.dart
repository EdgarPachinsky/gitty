import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/gitty_exception.dart';
import '../../core/widgets/state_views.dart';
import 'ollama_models_controller.dart';
import 'settings_controller.dart';

/// Progress bar with size, speed and time left, plus Pause/Resume and Stop.
class ModelDownloadProgress extends ConsumerWidget {
  const ModelDownloadProgress({
    super.key,
    required this.download,
    this.foreground,
  });

  final ModelDownload download;

  /// Text/icon colour when shown on a tinted banner.
  final Color? foreground;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(modelDownloadsProvider.notifier);
    final d = download;
    final color = foreground ?? theme.colorScheme.onSurfaceVariant;
    final small = theme.textTheme.bodySmall?.copyWith(color: color);

    if (d.phase == ModelDownloadPhase.failed) {
      final e = d.error ?? const GittyException('The download failed.');
      return Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [e.message, if (e.hint != null) e.hint!].join(' '),
              style: small,
            ),
          ),
          TextButton(
            onPressed: () => controller.install(d.model),
            child: const Text('Try again'),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: Icon(Icons.close_rounded, size: 18, color: color),
            onPressed: () => controller.stop(d.model),
          ),
        ],
      );
    }

    final paused = d.phase == ModelDownloadPhase.paused;
    final label = switch (d.phase) {
      ModelDownloadPhase.starting => 'Starting download…',
      ModelDownloadPhase.finishing => 'Almost done — checking the files…',
      ModelDownloadPhase.paused =>
        d.total > 0
            ? 'Paused · ${formatBytes(d.completed)} of ${formatBytes(d.total)}'
            : 'Paused',
      _ => [
        '${formatBytes(d.completed)} of ${formatBytes(d.total)}',
        if (d.bytesPerSecond != null && d.bytesPerSecond! > 0)
          '${formatBytes(d.bytesPerSecond!.round())}/s',
        if (d.timeLeft != null) formatTimeLeft(d.timeLeft!),
      ].join(' · '),
    };
    final indeterminate =
        d.phase == ModelDownloadPhase.starting ||
        d.phase == ModelDownloadPhase.finishing ||
        d.fraction == null;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: indeterminate && !paused ? null : (d.fraction ?? 0),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                d.fraction != null && !indeterminate
                    ? '${(d.fraction! * 100).floor()}% · $label'
                    : label,
                style: small,
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: paused ? 'Resume' : 'Pause',
          icon: Icon(
            paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            color: color,
          ),
          onPressed: d.phase == ModelDownloadPhase.finishing
              ? null
              : () {
                  if (paused) {
                    controller.install(d.model);
                  } else {
                    controller.pause(d.model);
                  }
                },
        ),
        IconButton(
          tooltip: 'Stop',
          icon: Icon(Icons.stop_rounded, color: color),
          onPressed: () => controller.stop(d.model),
        ),
      ],
    );
  }
}

/// Asks, then deletes [model] from Ollama. Shows a snackbar either way.
Future<void> confirmDeleteModel(
  BuildContext context,
  WidgetRef ref,
  String model,
) async {
  final inUse = sameOllamaModel(
    model,
    ref.read(settingsControllerProvider).ollamaModel,
  );
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete $model?'),
      content: Text(
        [
          'This removes the model from Ollama and frees its disk space. '
              'You can install it again anytime.',
          if (inUse)
            'Gitty uses it for commit messages right now — pick another model '
                'afterwards.',
        ].join('\n\n'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await ref.read(modelDownloadsProvider.notifier).delete(model);
    if (context.mounted) {
      showFriendlySnack(context, message: 'Deleted $model.');
    }
  } catch (e) {
    final error = toGittyException(e);
    if (context.mounted) {
      showFriendlySnack(context, message: error.message, error: error);
    }
  }
}

/// "Install another model" — any name from ollama.com/library.
class InstallModelField extends ConsumerStatefulWidget {
  const InstallModelField({super.key, this.hideModels = const {}});

  /// Downloads shown elsewhere (e.g. in the fast-models hint).
  final Set<String> hideModels;

  @override
  ConsumerState<InstallModelField> createState() => _InstallModelFieldState();
}

class _InstallModelFieldState extends ConsumerState<InstallModelField> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _install() {
    final model = _name.text.trim();
    if (model.isEmpty) return;
    ref.read(modelDownloadsProvider.notifier).install(model);
    _name.clear();
  }

  @override
  Widget build(BuildContext context) {
    final downloads = ref
        .watch(modelDownloadsProvider)
        .values
        .where((d) => !widget.hideModels.contains(d.model))
        .toList();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _name,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Install another model',
                  hintText: 'e.g. gemma3:4b — see ollama.com/library',
                  prefixIcon: Icon(Icons.download_rounded, size: 20),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _install(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _name.text.trim().isEmpty ? null : _install,
              child: const Text('Install'),
            ),
          ],
        ),
        for (final d in downloads) ...[
          const SizedBox(height: 10),
          Text(d.model, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          ModelDownloadProgress(download: d),
        ],
      ],
    );
  }
}
