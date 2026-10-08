import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/gitty_exception.dart';
import '../../core/widgets/state_views.dart';
import '../../services/auth/git_provider.dart';
import '../../services/service_providers.dart';
import 'account_controller.dart';

/// Connect / show / disconnect a GitHub account using the device flow.
/// Used in onboarding and in Settings.
class GitHubConnectCard extends ConsumerStatefulWidget {
  const GitHubConnectCard({super.key});

  @override
  ConsumerState<GitHubConnectCard> createState() => _GitHubConnectCardState();
}

class _GitHubConnectCardState extends ConsumerState<GitHubConnectCard> {
  DeviceCodeChallenge? _challenge;
  bool _starting = false;
  GittyException? _error;

  /// Incremented on every attempt/cancel so a stale polling loop stops.
  int _attempt = 0;

  Future<void> _connect() async {
    final attempt = ++_attempt;
    setState(() {
      _starting = true;
      _error = null;
    });
    final controller = ref.read(accountProvider.notifier);
    try {
      final challenge = await controller.startSignIn();
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _starting = false;
      });
      // Open the verification page for the user automatically (real mode).
      if (!controller.isDemoMode) {
        try {
          await Clipboard.setData(ClipboardData(text: challenge.userCode));
          await ref
              .read(systemLauncherProvider)
              .openUrl(challenge.verificationUri);
        } catch (_) {
          // The user can still use the "Open GitHub" button.
        }
      }
      await controller.completeSignIn(
        challenge,
        isCancelled: () => !mounted || attempt != _attempt,
      );
      if (mounted && attempt == _attempt) setState(() => _challenge = null);
    } on SignInCancelled {
      // User cancelled; nothing to report.
    } catch (e) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _error = toGittyException(e);
        _challenge = null;
        _starting = false;
      });
    }
  }

  void _cancel() => setState(() {
    _attempt++;
    _challenge = null;
    _starting = false;
  });

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final isDemo = ref.watch(githubProvider.select((p) => !p.isConfigured));
    final theme = Theme.of(context);

    Widget body;
    if (_challenge != null) {
      body = _WaitingForApproval(
        challenge: _challenge!,
        isDemo: isDemo,
        onOpen: () => ref
            .read(systemLauncherProvider)
            .openUrl(_challenge!.verificationUri),
        onCancel: _cancel,
      );
    } else {
      body = account.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(8),
          child: LinearProgressIndicator(),
        ),
        error: (e, _) => ErrorView(
          error: e,
          compact: true,
          onRetry: () => ref.invalidate(accountProvider),
        ),
        data: (acc) => acc == null
            ? _NotConnected(
                starting: _starting,
                onConnect: _connect,
                error: _error,
              )
            : _Connected(
                account: acc,
                onDisconnect: () =>
                    ref.read(accountProvider.notifier).signOut(),
              ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.hub_outlined),
                const SizedBox(width: 10),
                Text('GitHub', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (isDemo)
                  Tooltip(
                    message:
                        'No GITHUB_CLIENT_ID configured — sign-in is simulated.\n'
                        'Build with --dart-define=GITHUB_CLIENT_ID=<id> to connect for real.',
                    child: Chip(
                      label: const Text('Demo mode'),
                      avatar: const Icon(Icons.science_outlined, size: 16),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: theme.colorScheme.tertiaryContainer,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: body,
            ),
          ],
        ),
      ),
    );
  }
}

class _NotConnected extends StatelessWidget {
  const _NotConnected({
    required this.starting,
    required this.onConnect,
    this.error,
  });

  final bool starting;
  final VoidCallback onConnect;
  final GittyException? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Connect your account to browse and clone your repositories. '
          'Gitty only asks for what it needs, and your token stays in your system keychain.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(
            [error!.message, if (error!.hint != null) error!.hint!].join(' '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: starting ? null : onConnect,
          icon: starting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link),
          label: const Text('Connect GitHub'),
        ),
      ],
    );
  }
}

class _WaitingForApproval extends StatelessWidget {
  const _WaitingForApproval({
    required this.challenge,
    required this.isDemo,
    required this.onOpen,
    required this.onCancel,
  });

  final DeviceCodeChallenge challenge;
  final bool isDemo;
  final VoidCallback onOpen;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isDemo
              ? 'Demo: pretending you approved this code on GitHub…'
              : 'Enter this code on GitHub to approve Gitty (it’s already copied):',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                challenge.userCode,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 3,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Copy code',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: challenge.userCode)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Waiting for approval…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (!isDemo)
              TextButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open GitHub'),
              ),
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }
}

class _Connected extends StatelessWidget {
  const _Connected({required this.account, required this.onDisconnect});

  final ProviderAccount account;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = account.username.isEmpty
        ? '?'
        : account.username[0].toUpperCase();
    return Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundImage: account.avatarUrl == null
              ? null
              : NetworkImage(account.avatarUrl!),
          child: account.avatarUrl == null ? Text(initial) : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                account.displayName ?? account.username,
                style: theme.textTheme.titleSmall,
              ),
              Text(
                '@${account.username} · connected${account.isDemo ? ' (demo)' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        TextButton(onPressed: onDisconnect, child: const Text('Disconnect')),
      ],
    );
  }
}
