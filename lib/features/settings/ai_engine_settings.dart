import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/gitty_exception.dart';
import '../../core/widgets/state_views.dart';
import '../../services/ai/ai_engine.dart';
import '../../services/ai/claude_client.dart';
import '../../services/ai/llm_client.dart';
import '../../services/ai/openai_client.dart';
import '../../services/service_providers.dart';
import 'settings_controller.dart';

/// Models a cloud engine offers (empty until a key is saved, for Claude).
final aiModelsProvider = FutureProvider.autoDispose
    .family<List<AiModel>, AiEngine>((ref, engine) async {
      switch (engine) {
        case AiEngine.claude:
          final key = await ref.watch(aiApiKeyProvider(engine).future);
          if (key == null || key.isEmpty) return const [];
          return ref.watch(claudeClientProvider).listModels();
        case AiEngine.openAi:
          await ref.watch(aiApiKeyProvider(engine).future);
          return ref.watch(openAiClientProvider).listModels();
        case AiEngine.ollama:
          return const [];
      }
    });

/// "Which AI writes my commit messages?" — Local, Claude or
/// OpenAI-compatible.
class AiEngineSelector extends ConsumerWidget {
  const AiEngineSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final engine = ref.watch(settingsControllerProvider.select((s) => s.aiEngine));
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // (The card's own header already says "AI engine".)
          Text(
            'Local keeps everything on this computer; cloud engines are '
            'smarter and need an API key.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<AiEngine>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: AiEngine.ollama,
                  icon: Icon(Icons.computer_outlined, size: 18),
                  label: Text('Local'),
                ),
                ButtonSegment(
                  value: AiEngine.claude,
                  icon: Icon(Icons.auto_awesome_outlined, size: 18),
                  label: Text('Claude'),
                ),
                ButtonSegment(
                  value: AiEngine.openAi,
                  icon: Icon(Icons.hub_outlined, size: 18),
                  label: Text('OpenAI-compatible'),
                ),
              ],
              selected: {engine},
              onSelectionChanged: (s) => ref
                  .read(settingsControllerProvider.notifier)
                  .change((c) => c.copyWith(aiEngine: s.first)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Key, model and fallback settings for Claude or an OpenAI-compatible
/// server.
class CloudEngineSettings extends ConsumerStatefulWidget {
  const CloudEngineSettings({super.key, required this.engine});

  final AiEngine engine;

  @override
  ConsumerState<CloudEngineSettings> createState() =>
      _CloudEngineSettingsState();
}

class _CloudEngineSettingsState extends ConsumerState<CloudEngineSettings> {
  final _key = TextEditingController();
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  bool _editingKey = false;
  bool _obscure = true;
  bool _savingKey = false;

  AiEngine get _engine => widget.engine;
  bool get _isClaude => _engine == AiEngine.claude;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsControllerProvider);
    _baseUrl = TextEditingController(text: s.openAiBaseUrl);
    _model = TextEditingController(
      text: _isClaude ? s.claudeModel : s.openAiModel,
    );
  }

  @override
  void didUpdateWidget(covariant CloudEngineSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      final s = ref.read(settingsControllerProvider);
      _model.text = _isClaude ? s.claudeModel : s.openAiModel;
      _key.clear();
      _editingKey = false;
    }
  }

  @override
  void dispose() {
    _key.dispose();
    _baseUrl.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _saveKey() async {
    final key = _key.text.trim();
    if (key.isEmpty) return;
    setState(() => _savingKey = true);
    try {
      await ref.read(tokenStoreProvider).write(_engine.keyId, key);
      _key.clear();
      _editingKey = false;
    } catch (e) {
      if (mounted) {
        showFriendlySnack(
          context,
          message: 'Couldn’t save the key to your keychain.',
          error: toGittyException(e),
        );
      }
    } finally {
      ref.invalidate(aiApiKeyProvider(_engine));
      if (mounted) setState(() => _savingKey = false);
    }
  }

  Future<void> _removeKey() async {
    await ref.read(tokenStoreProvider).delete(_engine.keyId);
    ref.invalidate(aiApiKeyProvider(_engine));
  }

  void _saveModel(String model) {
    final m = model.trim();
    if (m.isEmpty) return;
    _model.text = m;
    ref
        .read(settingsControllerProvider.notifier)
        .change(
          (c) => _isClaude
              ? c.copyWith(claudeModel: m)
              : c.copyWith(openAiModel: m),
        );
  }

  void _saveBaseUrl() {
    final url = _baseUrl.text.trim();
    if (url.isEmpty) return;
    ref
        .read(settingsControllerProvider.notifier)
        .change((c) => c.copyWith(openAiBaseUrl: url));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final key = ref.watch(aiApiKeyProvider(_engine));
    final hasKey = (key.value ?? '').isNotEmpty;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final local =
        !_isClaude && OpenAiCompatibleClient.isLocalAddress(settings.openAiBaseUrl);
    final destination = _isClaude
        ? 'Anthropic'
        : OpenAiCompatibleClient.friendlyName(settings.openAiBaseUrl);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Note(
            icon: local ? Icons.lock_outline : Icons.cloud_upload_outlined,
            text: local
                ? 'This server runs on your computer — your code stays here.'
                : 'Only the staged diff is sent to $destination, and only when '
                      'you press “Generate with AI”. Your API key stays in the '
                      'system keychain.',
          ),
          const SizedBox(height: 14),
          if (!_isClaude) ...[
            TextField(
              controller: _baseUrl,
              decoration: const InputDecoration(
                labelText: 'Server address',
                helperText:
                    'e.g. https://api.openai.com/v1 · https://openrouter.ai/api/v1 · '
                    'http://localhost:1234/v1 (LM Studio)',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
              onSubmitted: (_) => _saveBaseUrl(),
              onTapOutside: (_) => _saveBaseUrl(),
            ),
            const SizedBox(height: 14),
          ],

          // --- API key ------------------------------------------------------
          if (hasKey && !_editingKey)
            Row(
              children: [
                const Icon(Icons.key_rounded, size: 20, color: Colors.green),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'API key saved · ••••${_lastFour(key.value!)}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _editingKey = true),
                  child: const Text('Replace'),
                ),
                TextButton(onPressed: _removeKey, child: const Text('Remove')),
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _key,
                    obscureText: _obscure,
                    enabled: !_savingKey,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: _isClaude
                          ? 'Claude API key'
                          : 'API key${local ? ' (usually not needed)' : ''}',
                      hintText: _isClaude ? 'sk-ant-…' : 'sk-…',
                      prefixIcon: const Icon(Icons.key_outlined),
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'Show' : 'Hide',
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    onSubmitted: (_) => _saveKey(),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FilledButton(
                    onPressed: _savingKey ? null : _saveKey,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          if (_isClaude && !hasKey)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => ref
                    .read(systemLauncherProvider)
                    .openUrl(ClaudeClient.keysPage),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Get an API key from the Claude Console'),
              ),
            ),
          const SizedBox(height: 14),

          // --- Model --------------------------------------------------------
          _ModelPicker(
            engine: _engine,
            controller: _model,
            current: _isClaude ? settings.claudeModel : settings.openAiModel,
            canList: !_isClaude || hasKey,
            onSelected: _saveModel,
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('If ${_isClaude ? 'Claude' : 'it'} can’t be reached, use local AI'),
            subtitle: Text(
              settings.aiEnabled
                  ? 'Falls back to ${settings.ollamaModel} via Ollama, then to a quick draft.'
                  : 'Local AI is off, so Gitty falls back to a quick draft.',
              style: muted,
            ),
            value: settings.aiFallbackToLocal,
            onChanged: (v) => ref
                .read(settingsControllerProvider.notifier)
                .change((c) => c.copyWith(aiFallbackToLocal: v)),
          ),
        ],
      ),
    );
  }

  static String _lastFour(String key) =>
      key.length <= 4 ? key : key.substring(key.length - 4);
}

class _ModelPicker extends ConsumerWidget {
  const _ModelPicker({
    required this.engine,
    required this.controller,
    required this.current,
    required this.canList,
    required this.onSelected,
  });

  final AiEngine engine;
  final TextEditingController controller;
  final String current;
  final bool canList;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final manual = TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: 'Model',
        hintText: engine == AiEngine.claude
            ? ClaudeClient.defaultModel
            : 'e.g. gpt-4o-mini',
        prefixIcon: const Icon(Icons.memory),
      ),
      onSubmitted: onSelected,
      onTapOutside: (_) => onSelected(controller.text),
    );

    if (!canList) return manual;

    final models = ref.watch(aiModelsProvider(engine));
    return models.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) {
        final error = toGittyException(e);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Note(
              icon: Icons.info_outline,
              color: theme.colorScheme.error,
              text: [error.message, if (error.hint != null) error.hint!].join(' '),
            ),
            const SizedBox(height: 10),
            manual,
            _CheckAgain(engine: engine),
          ],
        );
      },
      data: (list) {
        if (list.isEmpty) {
          return Column(children: [manual, _CheckAgain(engine: engine)]);
        }
        final known = list.any((m) => m.id == current);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Note(
              icon: Icons.check_circle,
              color: Colors.green,
              text: 'Connected — ${list.length} model(s) available.',
            ),
            const SizedBox(height: 12),
            DropdownMenu<String>(
              initialSelection: known ? current : null,
              label: const Text('Model'),
              leadingIcon: const Icon(Icons.memory),
              expandedInsets: EdgeInsets.zero,
              dropdownMenuEntries: [
                for (final m in list)
                  DropdownMenuEntry(
                    value: m.id,
                    label: m.label == m.id ? m.id : '${m.label}  ·  ${m.id}',
                  ),
              ],
              onSelected: (m) {
                if (m != null) onSelected(m);
              },
            ),
            if (!known && current.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '“$current” isn’t in the list — pick one above.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            _CheckAgain(engine: engine),
          ],
        );
      },
    );
  }
}

class _CheckAgain extends ConsumerWidget {
  const _CheckAgain({required this.engine});

  final AiEngine engine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () => ref.invalidate(aiModelsProvider(engine)),
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('Check again'),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color ?? theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}
