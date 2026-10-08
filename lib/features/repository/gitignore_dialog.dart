import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/gitty_exception.dart';
import '../../core/utils/time_ago.dart';
import '../../core/widgets/state_views.dart';
import '../../services/git/git_models.dart';
import '../../services/git/gitignore_templates.dart';
import '../../services/service_providers.dart';
import 'repo_actions_controller.dart';

/// Icon for a template chip / preview row.
IconData gitignoreIcon(String templateId) => switch (templateId) {
  'flutter' => Icons.flutter_dash,
  'node' => Icons.javascript,
  'python' => Icons.data_object,
  'java' => Icons.coffee_outlined,
  'swift' => Icons.apple,
  'go' => Icons.speed,
  'rust' => Icons.settings_suggest_outlined,
  'dotnet' => Icons.grid_view_rounded,
  'php' => Icons.php,
  'ruby' => Icons.diamond_outlined,
  'macos' => Icons.laptop_mac,
  'windows' => Icons.window,
  'linux' => Icons.computer,
  'secrets' => Icons.key_outlined,
  'editors' => Icons.edit_note_rounded,
  'logs' => Icons.receipt_long_outlined,
  _ => Icons.block,
};

/// The template for the OS Gitty is running on.
String get currentOsTemplateId => Platform.isMacOS
    ? 'macos'
    : Platform.isWindows
    ? 'windows'
    : 'linux';

/// Templates Gitty suggests for a folder: what it detected, this computer's
/// OS, and the always-useful habits.
Set<String> suggestedGitignoreTemplates(Set<String> detected) => {
  ...detected,
  currentOsTemplateId,
  'secrets',
  'editors',
  'logs',
};

/// Lets the user pick what to ignore, shows in plain language what that
/// means, and writes (or extends) the repository's .gitignore.
/// Returns the success message, or null if cancelled.
Future<String?> showGitignoreDialog(
  BuildContext context, {
  required String repoPath,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _GitignoreDialog(repoPath: repoPath),
  );
}

class _GitignoreDialog extends ConsumerStatefulWidget {
  const _GitignoreDialog({required this.repoPath});

  final String repoPath;

  @override
  ConsumerState<_GitignoreDialog> createState() => _GitignoreDialogState();
}

class _GitignoreDialogState extends ConsumerState<_GitignoreDialog> {
  bool _loading = true;

  /// Current .gitignore (null = none yet).
  String? _existing;
  Set<String> _detected = {};
  Set<String> _selected = {};
  final List<String> _custom = [];
  final _customController = TextEditingController();
  bool _showFile = false;

  GitignorePreview? _preview;
  bool _previewing = false;
  Timer? _debounce;
  int _previewGeneration = 0;
  GittyException? _error;

  bool get _hasFile => _existing != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _customController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final git = ref.read(gitServiceProvider);
    final results = await Future.wait([
      git.readGitignore(widget.repoPath),
      git.topLevelNames(widget.repoPath),
    ]);
    if (!mounted) return;
    final existing = results[0] as String?;
    final names = results[1] as List<String>;
    setState(() {
      _existing = existing;
      _detected = detectGitignoreTemplates(names);
      _selected = suggestedGitignoreTemplates(_detected);
      _loading = false;
    });
    _schedulePreview();
  }

  List<GitignoreTemplate> get _selectedTemplates => [
    for (final t in gitignoreTemplates)
      if (_selected.contains(t.id)) t,
  ];

  /// Exactly what will be written (full file, or the block to append).
  String get _content =>
      buildGitignore(_selectedTemplates, custom: _custom, existing: _existing);

  int get _newRuleCount => gitignoreRules(_content).length;

  void _toggle(String id, bool on) {
    setState(() => on ? _selected.add(id) : _selected.remove(id));
    _schedulePreview();
  }

  void _addCustom() {
    final rule = _customController.text.trim();
    if (rule.isEmpty) return;
    setState(() {
      if (!_custom.contains(rule)) _custom.add(rule);
      _customController.clear();
    });
    _schedulePreview();
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _runPreview);
  }

  Future<void> _runPreview() async {
    if (!mounted) return;
    final generation = ++_previewGeneration;
    final content = _content;
    if (content.isEmpty) {
      setState(() {
        _preview = const GitignorePreview(newlyHidden: [], stillTracked: []);
        _previewing = false;
      });
      return;
    }
    setState(() => _previewing = true);
    try {
      final preview = await ref
          .read(gitServiceProvider)
          .previewGitignore(widget.repoPath, content);
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _preview = preview;
        _previewing = false;
      });
    } catch (_) {
      // The preview is a nicety; writing still works without it.
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _preview = null;
        _previewing = false;
      });
    }
  }

  Future<void> _save() async {
    final content = _content;
    if (content.isEmpty) return;
    setState(() => _error = null);
    final outcome = await ref
        .read(repoActionsProvider(widget.repoPath).notifier)
        .addGitignore(
          content,
          append: _hasFile,
          hidden: _preview?.newlyHidden.length ?? 0,
        );
    if (!mounted) return;
    if (outcome.ok) {
      Navigator.pop(context, outcome.message);
    } else {
      setState(() => _error = outcome.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saving =
        ref.watch(repoActionsProvider(widget.repoPath)) == GitAction.gitignore;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    if (_loading) {
      return const AlertDialog(
        content: SizedBox(
          width: 320,
          height: 160,
          child: LoadingView(message: 'Looking at your project…'),
        ),
      );
    }

    final newRules = _newRuleCount;
    final existingRules = _hasFile ? gitignoreRules(_existing!) : <String>{};

    return AlertDialog(
      title: Text(_hasFile ? 'Add to .gitignore' : 'Add a .gitignore'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A .gitignore tells Git which files to leave alone — they stay '
                'on your computer but never end up in a commit. Pick what fits '
                'this project; you’ll see exactly what that means below.',
                style: muted,
              ),
              const SizedBox(height: 20),
              for (final category in GitignoreCategory.values)
                _TemplateGroup(
                  category: category,
                  detected: _detected,
                  selected: _selected,
                  enabled: !saving,
                  onToggle: _toggle,
                ),
              _CustomRules(
                controller: _customController,
                rules: _custom,
                enabled: !saving,
                onAdd: _addCustom,
                onRemove: (rule) {
                  setState(() => _custom.remove(rule));
                  _schedulePreview();
                },
              ),
              const SizedBox(height: 20),
              Text('What will be ignored', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              _WhatWillBeIgnored(
                templates: _selectedTemplates,
                custom: _custom,
                existingRules: existingRules,
              ),
              const SizedBox(height: 12),
              _EffectSummary(preview: _preview, loading: _previewing),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: newRules == 0
                        ? null
                        : () => setState(() => _showFile = !_showFile),
                    icon: Icon(
                      _showFile
                          ? Icons.expand_less_rounded
                          : Icons.description_outlined,
                      size: 18,
                    ),
                    label: Text(
                      _showFile
                          ? 'Hide the file'
                          : _hasFile
                          ? 'Show what gets added'
                          : 'Show the file',
                    ),
                  ),
                  const Spacer(),
                  if (_hasFile)
                    Text(
                      'Your current rules stay exactly as they are.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              if (_showFile && newRules > 0) _FilePreview(content: _content),
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
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: saving || newRules == 0 ? null : _save,
          icon: saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded),
          label: Text(
            newRules == 0
                ? 'Nothing new to add'
                : _hasFile
                ? 'Add ${plural(newRules, 'rule')}'
                : 'Create .gitignore',
          ),
        ),
      ],
    );
  }
}

/// One category of template chips ("For your project", …).
class _TemplateGroup extends StatelessWidget {
  const _TemplateGroup({
    required this.category,
    required this.detected,
    required this.selected,
    required this.enabled,
    required this.onToggle,
  });

  final GitignoreCategory category;
  final Set<String> detected;
  final Set<String> selected;
  final bool enabled;
  final void Function(String id, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inCategory = [
      for (final t in gitignoreTemplates)
        if (t.category == category) t,
    ];
    // Detected project types first, otherwise keep the catalogue order.
    final templates = [
      ...inCategory.where((t) => detected.contains(t.id)),
      ...inCategory.where((t) => !detected.contains(t.id)),
    ];
    final os = currentOsTemplateId;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(category.label, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in templates)
                Tooltip(
                  message: t.summary,
                  child: FilterChip(
                    avatar: Icon(gitignoreIcon(t.id), size: 18),
                    showCheckmark: false,
                    label: Text(
                      detected.contains(t.id)
                          ? '${t.label} · detected'
                          : t.id == os
                          ? '${t.label} · this computer'
                          : t.label,
                    ),
                    selected: selected.contains(t.id),
                    onSelected: enabled ? (on) => onToggle(t.id, on) : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CustomRules extends StatelessWidget {
  const _CustomRules({
    required this.controller,
    required this.rules,
    required this.enabled,
    required this.onAdd,
    required this.onRemove,
  });

  final TextEditingController controller;
  final List<String> rules;
  final bool enabled;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Anything else?', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'e.g. secrets.json, uploads/, *.zip',
                  prefixIcon: Icon(Icons.add_rounded, size: 20),
                ),
                style: const TextStyle(fontFamily: 'monospace'),
                onSubmitted: (_) => onAdd(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: enabled ? onAdd : null,
              child: const Text('Add rule'),
            ),
          ],
        ),
        if (rules.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final rule in rules)
                InputChip(
                  label: Text(
                    rule,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  onDeleted: enabled ? () => onRemove(rule) : null,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Plain-language breakdown of the selected rules.
class _WhatWillBeIgnored extends StatelessWidget {
  const _WhatWillBeIgnored({
    required this.templates,
    required this.custom,
    required this.existingRules,
  });

  final List<GitignoreTemplate> templates;
  final List<String> custom;
  final Set<String> existingRules;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final rows = <Widget>[
      for (final t in templates)
        for (final s in t.sections)
          _RuleRow(
            icon: gitignoreIcon(t.id),
            title: '${s.title} · ${t.label}',
            why: s.why,
            patterns: s.patterns,
            existingRules: existingRules,
          ),
      if (custom.isNotEmpty)
        _RuleRow(
          icon: Icons.person_outline,
          title: 'Your own rules',
          why: 'Added by you.',
          patterns: custom,
          existingRules: existingRules,
        ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      constraints: const BoxConstraints(maxHeight: 280),
      child: rows.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Pick at least one option above.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView.separated(
              shrinkWrap: true,
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => rows[i],
            ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.icon,
    required this.title,
    required this.why,
    required this.patterns,
    required this.existingRules,
  });

  final IconData icon;
  final String title;
  final String why;
  final List<String> patterns;
  final Set<String> existingRules;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final allThere =
        existingRules.isNotEmpty && patterns.every(existingRules.contains);

    return Opacity(
      opacity: allThere ? 0.55 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(title, style: theme.textTheme.titleSmall),
                      ),
                      if (allThere) ...[
                        const SizedBox(width: 8),
                        Text(
                          'already in your .gitignore',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    why,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final pattern in patterns)
                        _PatternPill(
                          pattern: pattern,
                          present: existingRules.contains(pattern),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PatternPill extends StatelessWidget {
  const _PatternPill({required this.pattern, required this.present});

  final String pattern;
  final bool present;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keep = pattern.startsWith('!');
    return Tooltip(
      message: present
          ? 'Already in your .gitignore'
          : keep
          ? 'Kept: “${pattern.substring(1)}” is still committed'
          : _explainPattern(pattern),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: keep ? scheme.tertiaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        child: Text(
          pattern,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: keep ? scheme.onTertiaryContainer : scheme.onSurface,
            decoration: present ? TextDecoration.lineThrough : null,
          ),
        ),
      ),
    );
  }

  static String _explainPattern(String pattern) {
    if (pattern.startsWith('**/')) {
      return 'Matches “${pattern.substring(3)}” in any folder';
    }
    if (pattern.endsWith('/')) return 'The whole folder, wherever it appears';
    if (pattern.startsWith('*.')) {
      return 'Every file ending in ${pattern.substring(1)}';
    }
    if (pattern.contains('*')) return 'Anything matching this pattern';
    return 'Any file or folder named exactly this';
  }
}

/// Live "here's what disappears from your changes" line.
class _EffectSummary extends StatelessWidget {
  const _EffectSummary({required this.preview, required this.loading});

  final GitignorePreview? preview;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;

    Widget line(IconData icon, Color color, String text) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: small)),
        ],
      ),
    );

    if (loading && preview == null) {
      return line(
        Icons.hourglass_empty_rounded,
        scheme.onSurfaceVariant,
        'Checking what this would hide…',
      );
    }
    final p = preview;
    if (p == null) return const SizedBox.shrink();

    String examples(List<String> paths) {
      final shown = paths.take(4).join(', ');
      final more = paths.length - 4;
      return more > 0 ? '$shown and $more more' : shown;
    }

    final parts = [
      if (p.hiddenFolders > 0) plural(p.hiddenFolders, 'folder'),
      if (p.hiddenFiles > 0) plural(p.hiddenFiles, 'file'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (p.newlyHidden.isEmpty)
          line(
            Icons.check_circle_outline,
            scheme.primary,
            'Nothing in your changes matches yet — these rules will keep '
            'future clutter out.',
          )
        else
          line(
            Icons.visibility_off_outlined,
            scheme.primary,
            'Hides ${parts.join(' and ')} that show up in your changes today: '
            '${examples(p.newlyHidden)}.',
          ),
        if (p.stillTracked.isNotEmpty)
          line(
            Icons.info_outline,
            scheme.tertiary,
            '${plural(p.stillTracked.length, 'committed file')} already match '
            '(${examples(p.stillTracked)}). Git keeps tracking '
            '${p.stillTracked.length == 1 ? 'it' : 'them'} until removed with '
            '“git rm --cached <file>” — the file${p.stillTracked.length == 1 ? '' : 's'} '
            'stay on your computer.',
          ),
      ],
    );
  }
}

class _FilePreview extends StatelessWidget {
  const _FilePreview({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          content.trimLeft(),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}
