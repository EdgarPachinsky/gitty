import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/system_memory.dart';

import '../../services/ai/ai_engine.dart';
import '../../services/ai/commit_style.dart';
import '../../services/service_providers.dart';
import '../account/github_connect_card.dart';
import 'ai_engine_settings.dart';
import 'model_install_widgets.dart';
import 'ollama_models_controller.dart';
import 'settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final theme = Theme.of(context);

    // Cards in reading order; [weight] is a rough height used to balance
    // the columns.
    final cards = <(double, Widget)>[
      (
        7,
        _SectionCard(
          icon: Icons.auto_awesome_outlined,
          title: 'AI engine',
          subtitle: 'Who writes your “Generate with AI” messages.',
          children: [
                    const AiEngineSelector(),
                    const Divider(height: 1),
                    if (settings.aiEngine == AiEngine.ollama) ...[
                      SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 8,
                        ),
                        title: const Text('Use local AI (Ollama)'),
                        subtitle: const Text(
                          'Diffs are sent only to Ollama on this computer. When off, Gitty writes a simple draft instead.',
                        ),
                        value: settings.aiEnabled,
                        onChanged: (v) =>
                            controller.change((c) => c.copyWith(aiEnabled: v)),
                      ),
                      if (settings.aiEnabled) ...[
                        const Divider(height: 1),
                        const _OllamaSettings(),
                        const _FastModelsHint(),
                      ],
                    ] else
                      CloudEngineSettings(engine: settings.aiEngine),
                  
          ],
        ),
      ),
      (
        1.4,
        _SectionCard(
          icon: Icons.palette_outlined,
          title: 'Appearance',
          subtitle: 'How Gitty looks.',
          children: [
                    ListTile(
                      title: const Text('Theme'),
                      trailing: SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('System'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text('Light'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text('Dark'),
                          ),
                        ],
                        selected: {settings.themeMode},
                        onSelectionChanged: (s) => controller.change(
                          (c) => c.copyWith(themeMode: s.first),
                        ),
                      ),
                    ),
                  
          ],
        ),
      ),
      (
        1.8,
        _SectionCard(
          icon: Icons.edit_note_rounded,
          title: 'Commit messages',
          subtitle: 'The style Gitty suggests by default.',
          children: [
                    ListTile(
                      title: const Text('Default style'),
                      subtitle: const Text(
                        'Each repository remembers the style you last used there.',
                      ),
                      trailing: DropdownButton<CommitStyle>(
                        value: settings.defaultCommitStyle,
                        underline: const SizedBox.shrink(),
                        borderRadius: BorderRadius.circular(12),
                        items: [
                          for (final s in CommitStyle.values)
                            DropdownMenuItem(value: s, child: Text(s.label)),
                        ],
                        onChanged: (s) {
                          if (s != null)
                            controller.change(
                              (c) => c.copyWith(defaultCommitStyle: s),
                            );
                        },
                      ),
                    ),

          ],
        ),
      ),
      (
        3.2,
        _SectionCard(
          icon: Icons.sync_rounded,
          title: 'Sync',
          subtitle: 'Staying up to date with your teammates.',
          children: [
                    SwitchListTile(
                      title: const Text('Gentle sync reminders'),
                      subtitle: const Text(
                        'Show a hint when a branch is behind or has diverged.',
                      ),
                      value: settings.syncReminders,
                      onChanged: (v) => controller.change(
                        (c) => c.copyWith(syncReminders: v),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      title: const Text('Fetch in the background'),
                      subtitle: const Text(
                        'Keeps “ahead/behind” accurate while Gitty is open. Never changes your files.',
                      ),
                      value: settings.autoFetch,
                      onChanged: (v) =>
                          controller.change((c) => c.copyWith(autoFetch: v)),
                    ),
                    if (settings.autoFetch)
                      ListTile(
                        title: const Text('Fetch every'),
                        trailing: DropdownButton<int>(
                          value:
                              const [
                                0,
                                5,
                                15,
                                30,
                                60,
                              ].contains(settings.autoFetchMinutes)
                              ? settings.autoFetchMinutes
                              : 0,
                          underline: const SizedBox.shrink(),
                          borderRadius: BorderRadius.circular(12),
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('None')),
                            DropdownMenuItem(
                              value: 5,
                              child: Text('5 minutes'),
                            ),
                            DropdownMenuItem(
                              value: 15,
                              child: Text('15 minutes'),
                            ),
                            DropdownMenuItem(
                              value: 30,
                              child: Text('30 minutes'),
                            ),
                            DropdownMenuItem(value: 60, child: Text('hour')),
                          ],
                          onChanged: (v) {
                            if (v != null)
                              controller.change(
                                (c) => c.copyWith(autoFetchMinutes: v),
                              );
                          },
                        ),
                      ),
                  
          ],
        ),
      ),
      (2.4, const GitHubConnectCard()),
      (
        2,
        _SectionCard(
          icon: Icons.info_outline,
          title: 'About',
          subtitle: 'Your setup at a glance.',
          children: [
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('Git'),
                      subtitle: Text(
                        ref
                            .watch(gitVersionProvider)
                            .when(
                              data: (v) =>
                                  v ??
                                  'Not found — install Git from git-scm.com',
                              loading: () => 'Checking…',
                              error: (_, _) => 'Unknown',
                            ),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.replay_rounded),
                      title: const Text('Show the welcome tour again'),
                      onTap: () => controller.change(
                        (c) => c.copyWith(onboardingComplete: false),
                      ),
                    ),
                  
          ],
        ),
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Settings', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    'Changes are saved as you make them.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _CardColumns(cards: cards),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lays cards out in 1–3 columns (by width), like the dashboard grid, but
/// letting each card keep its natural height. Cards go to the currently
/// shortest column so the columns end up roughly even.
class _CardColumns extends StatelessWidget {
  const _CardColumns({required this.cards});

  final List<(double, Widget)> cards;

  static const _minColumnWidth = 520.0;
  static const _gap = 16.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = ((constraints.maxWidth + _gap) / (_minColumnWidth + _gap))
            .floor()
            .clamp(1, 3);
        final columns = List.generate(count, (_) => <Widget>[]);
        final heights = List.filled(count, 0.0);
        for (final (weight, card) in cards) {
          var target = 0;
          for (var i = 1; i < count; i++) {
            if (heights[i] < heights[target]) target = i;
          }
          if (columns[target].isNotEmpty) {
            columns[target].add(const SizedBox(height: _gap));
          }
          columns[target].add(card);
          heights[target] += weight;
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: columns[i],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A settings card with a friendly header, in the dashboard card style.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _OllamaSettings extends ConsumerStatefulWidget {
  const _OllamaSettings();

  @override
  ConsumerState<_OllamaSettings> createState() => _OllamaSettingsState();
}

class _OllamaSettingsState extends ConsumerState<_OllamaSettings> {
  late final TextEditingController _url;
  late final TextEditingController _model;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsControllerProvider);
    _url = TextEditingController(text: s.ollamaBaseUrl);
    _model = TextEditingController(text: s.ollamaModel);
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    super.dispose();
  }

  void _saveUrl() {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    ref
        .read(settingsControllerProvider.notifier)
        .change((c) => c.copyWith(ollamaBaseUrl: url));
  }

  void _saveModel(String model) {
    final m = model.trim();
    if (m.isEmpty) return;
    _model.text = m;
    ref
        .read(settingsControllerProvider.notifier)
        .change((c) => c.copyWith(ollamaModel: m));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final models = ref.watch(ollamaModelsProvider);
    final current = ref.watch(
      settingsControllerProvider.select((s) => s.ollamaModel),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Ollama address',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
            onSubmitted: (_) => _saveUrl(),
            onTapOutside: (_) => _saveUrl(),
          ),
          const SizedBox(height: 18),
          models.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) =>
                _status(theme, ok: false, text: 'Couldn’t talk to Ollama.'),
            data: (list) {
              if (list.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _status(
                      theme,
                      ok: false,
                      text:
                          'Ollama isn’t running (or has no models). Install it from ollama.com, then run '
                          '“ollama pull llama3.2”. Until then Gitty uses quick drafts.',
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _model,
                      decoration: const InputDecoration(
                        labelText: 'Model name',
                        prefixIcon: Icon(Icons.memory),
                      ),
                      onSubmitted: _saveModel,
                      onTapOutside: (_) => _saveModel(_model.text),
                    ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _status(
                    theme,
                    ok: true,
                    text: 'Connected — ${list.length} model(s) installed.',
                  ),
                  const SizedBox(height: 18),
                  DropdownMenu<String>(
                    initialSelection: list.contains(current) ? current : null,
                    label: const Text('Model'),
                    leadingIcon: const Icon(Icons.memory),
                    expandedInsets: EdgeInsets.zero,
                    dropdownMenuEntries: [
                      for (final m in list)
                        DropdownMenuEntry(
                          value: m,
                          label: m,
                          trailingIcon: IconButton(
                            tooltip: 'Delete $m',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () =>
                                confirmDeleteModel(context, ref, m),
                          ),
                        ),
                    ],
                    onSelected: (m) {
                      if (m != null) _saveModel(m);
                    },
                  ),
                  if (!list.contains(current))
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '“$current” isn’t installed — pick one above or run “ollama pull $current”.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                          if (!ref.watch(
                            modelDownloadsProvider.select(
                              (d) => d.containsKey(current),
                            ),
                          ))
                            TextButton.icon(
                              onPressed: () => ref
                                  .read(modelDownloadsProvider.notifier)
                                  .install(current),
                              icon: const Icon(
                                Icons.download_rounded,
                                size: 18,
                              ),
                              label: const Text('Install it'),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 22),
          InstallModelField(
            hideModels: {
              for (final m in [
                _FastModelsHint._big,
                _FastModelsHint._mid,
                _FastModelsHint._small,
              ])
                m.name,
            },
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => ref.invalidate(ollamaModelsProvider),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Check again'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _status(ThemeData theme, {required bool ok, required String text}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.info_outline,
          size: 18,
          color: ok ? Colors.green : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}

/// Suggests small, non-thinking local models that write commit messages in
/// seconds — with one-click Install (progress, pause, stop), Use and Delete.
class _FastModelsHint extends ConsumerWidget {
  const _FastModelsHint();

  static const _big = (
    name: 'qwen2.5-coder:7b',
    about: 'Qwen · about 4.7 GB download · tuned for code, best messages',
  );
  static const _mid = (
    name: 'qwen2.5-coder:3b',
    about: 'Qwen · about 2 GB download · tuned for code, quick',
  );
  static const _small = (
    name: 'qwen2.5-coder:1.5b',
    about: 'Qwen · about 1 GB download · tuned for code, very light',
  );

  /// Best first: what this computer runs comfortably.
  static List<({String name, String about})> _modelsFor(int? gb) {
    if (gb == null) return [_mid, _big];
    if (gb >= 16) return [_big, _mid];
    if (gb >= 8) return [_mid, _big];
    return [_small, _mid];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = scheme.onSecondaryContainer;
    final installed = ref.watch(ollamaModelsProvider).value ?? const [];
    final downloads = ref.watch(modelDownloadsProvider);
    final current = ref.watch(
      settingsControllerProvider.select((s) => s.ollamaModel),
    );
    final memory = ref.watch(totalMemoryGbProvider).value;
    final models = _modelsFor(memory);
    final codeModel = current.toLowerCase().contains('coder');

    String? installedName(String model) {
      for (final m in installed) {
        if (sameOllamaModel(m, model)) return m;
      }
      return null;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 8),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_awesome_rounded, color: fg, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    [
                      if (!codeModel)
                        '“$current” is a general model — models tuned for '
                            'code understand your changes much better and '
                            'write clearer messages and summaries.',
                      memory == null
                          ? 'Recommended:'
                          : 'Recommended for this computer ($memory GB memory):',
                    ].join(' '),
                    style: TextStyle(color: fg),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (final m in models)
              Padding(
                padding: const EdgeInsets.only(left: 32, bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    m.name,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontFamily: 'monospace',
                                      color: fg,
                                    ),
                                  ),
                                  if (m == models.first) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: fg.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'Best fit',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(color: fg),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              Text(
                                m.about,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: fg,
                                ),
                              ),
                            ],
                          ),
                        ),
                        ..._actions(
                          context,
                          ref,
                          model: m.name,
                          installedAs: installedName(m.name),
                          inUse: sameOllamaModel(current, m.name),
                          downloading: downloads.containsKey(m.name),
                          fg: fg,
                        ),
                      ],
                    ),
                    if (downloads[m.name] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 4),
                        child: ModelDownloadProgress(
                          download: downloads[m.name]!,
                          foreground: fg,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(
    BuildContext context,
    WidgetRef ref, {
    required String model,
    required String? installedAs,
    required bool inUse,
    required bool downloading,
    required Color fg,
  }) {
    if (downloading) return const []; // Progress row has the controls.
    if (installedAs == null) {
      return [
        FilledButton.tonalIcon(
          onPressed: () =>
              ref.read(modelDownloadsProvider.notifier).install(model),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Install'),
        ),
      ];
    }
    return [
      if (inUse)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, size: 16, color: fg),
              const SizedBox(width: 6),
              Text('In use', style: TextStyle(color: fg)),
            ],
          ),
        )
      else
        TextButton(
          onPressed: () => ref
              .read(settingsControllerProvider.notifier)
              .change((c) => c.copyWith(ollamaModel: installedAs)),
          child: const Text('Use it'),
        ),
      IconButton(
        tooltip: 'Delete $model',
        icon: Icon(Icons.delete_outline, color: fg),
        onPressed: () => confirmDeleteModel(context, ref, installedAs),
      ),
    ];
  }
}
