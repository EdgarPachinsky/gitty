import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/state_views.dart';
import '../../services/service_providers.dart';
import '../account/github_connect_card.dart';
import '../dashboard/add_repo_actions.dart';
import '../dashboard/tracked_repos_controller.dart';
import '../settings/settings_controller.dart';

/// First-launch flow: welcome → connect GitHub (optional) → add repositories.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _stepCount = 3;
  int _step = 0;

  /// Scanned repositories the user wants to add (null until the scan finishes).
  Set<String>? _selected;
  bool _finishing = false;

  void _next() => setState(() => _step = (_step + 1).clamp(0, _stepCount - 1));
  void _back() => setState(() => _step = (_step - 1).clamp(0, _stepCount - 1));

  Future<void> _finish() async {
    setState(() => _finishing = true);
    // If the user never touched the list, everything found is selected.
    final roots =
        _selected ??
        ref.read(repoScanProvider).value?.toSet() ??
        const <String>{};
    await ref.read(trackedReposProvider.notifier).addRoots(roots);
    await ref
        .read(settingsControllerProvider.notifier)
        .change((s) => s.copyWith(onboardingComplete: true));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = [
      const _WelcomeStep(),
      const _ConnectStep(),
      _AddReposStep(
        selected: _selected,
        onSelectionChanged: (s) => setState(() => _selected = s),
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
              child: Column(
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0.03, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(_step),
                        child: steps[_step],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      if (_step > 0)
                        TextButton(
                          onPressed: _finishing ? null : _back,
                          child: const Text('Back'),
                        )
                      else
                        const SizedBox(width: 64),
                      const Spacer(),
                      for (var i = 0; i < _stepCount; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: i == _step ? 22 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: i == _step
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      const Spacer(),
                      if (_step == 0)
                        FilledButton(
                          onPressed: _next,
                          child: const Text("Let's go"),
                        )
                      else if (_step == 1)
                        FilledButton(
                          onPressed: _next,
                          child: const Text('Continue'),
                        )
                      else
                        FilledButton.icon(
                          onPressed: _finishing ? null : _finish,
                          icon: const Icon(
                            Icons.rocket_launch_outlined,
                            size: 18,
                          ),
                          label: Text(
                            (_selected?.isNotEmpty ?? false)
                                ? 'Open Gitty with ${_selected!.length}'
                                : 'Open Gitty',
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [scheme.primary, scheme.tertiary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Icon(Icons.eco_rounded, size: 56, color: scheme.onPrimary),
            ),
            const SizedBox(height: 28),
            Text(
              'Hi, I’m Gitty',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Git, minus the stress. I’ll keep your repositories tidy and in sync, '
              'and explain things along the way.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 36),
            const _Feature(
              icon: Icons.touch_app_outlined,
              title: 'Big, friendly buttons',
              text: 'Commit, push, pull and branch in one click.',
            ),
            const _Feature(
              icon: Icons.auto_awesome_outlined,
              title: 'Commit messages, written for you',
              text:
                  'Generated by a local AI model (Ollama) — your code never leaves your machine.',
            ),
            const _Feature(
              icon: Icons.notifications_none_rounded,
              title: 'Gentle reminders',
              text:
                  'I’ll let you know when you’re behind, before it becomes a merge headache.',
            ),
          ],
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectStep extends ConsumerWidget {
  const _ConnectStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final gitVersion = ref.watch(gitVersionProvider);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text('Connect your accounts', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Optional — you can do this later in Settings. Local repositories work without an account.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          const GitHubConnectCard(),
          const SizedBox(height: 12),
          Text(
            'GitLab, Bitbucket and Gitea are coming soon.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          // Early, friendly check that Git itself is installed.
          gitVersion.when(
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
            data: (version) => _GitCheck(version: version),
          ),
        ],
      ),
    );
  }
}

class _GitCheck extends StatelessWidget {
  const _GitCheck({required this.version});

  final String? version;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = version != null;
    return Row(
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.warning_amber_rounded,
          size: 18,
          color: ok ? Colors.green : theme.colorScheme.error,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ok
                ? 'Git is installed ($version).'
                : 'Git isn’t installed yet. Get it from git-scm.com (macOS: run “xcode-select --install”).',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _AddReposStep extends ConsumerWidget {
  const _AddReposStep({
    required this.selected,
    required this.onSelectionChanged,
  });

  final Set<String>? selected;
  final ValueChanged<Set<String>> onSelectionChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scan = ref.watch(repoScanProvider);
    final trackedCount = ref.watch(trackedReposProvider).length;

    // Pre-select everything once the scan completes.
    ref.listen(repoScanProvider, (previous, next) {
      final paths = next.value;
      if (paths != null && selected == null) onSelectionChanged(paths.toSet());
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text('Add your repositories', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'I looked in the usual places for Git repositories. Pick the ones you want to see in Gitty.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => pickAndAddRepository(context, ref),
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('Add a folder…'),
            ),
            OutlinedButton.icon(
              onPressed: () => showCloneDialog(context),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Clone…'),
            ),
            if (trackedCount > 0)
              Chip(
                avatar: const Icon(Icons.check, size: 16),
                label: Text('$trackedCount already added'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: scan.when(
                loading: () => const LoadingView(
                  message: 'Looking around for repositories…',
                ),
                error: (e, _) => ErrorView(
                  error: e,
                  onRetry: () => ref.invalidate(repoScanProvider),
                ),
                data: (paths) => paths.isEmpty
                    ? const EmptyState(
                        icon: Icons.travel_explore,
                        title: 'No repositories found nearby',
                        message:
                            'Add a folder or clone one — or skip this and do it later.',
                      )
                    : RepoPathChecklist(
                        paths: paths,
                        selected: selected ?? paths.toSet(),
                        onChanged: onSelectionChanged,
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
