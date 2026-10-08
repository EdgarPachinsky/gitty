import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/state_views.dart';
import '../../../services/auth/git_provider.dart';
import '../../../services/git/git_models.dart';
import '../../../services/git/git_service.dart';
import '../../account/account_controller.dart';
import '../repo_actions_controller.dart';

/// "Who's committing?" for one repository.
///
/// Without a name/email Git refuses to commit; this card asks for them in a
/// friendly way and saves them with `git config --local` — only for this
/// folder, never globally. When they're set it shrinks to a one-line
/// summary with a "Change…" button. Styled like the other side cards.
class GitIdentityCard extends ConsumerWidget {
  const GitIdentityCard({super.key, required this.repoPath});

  final String repoPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final identity = ref.watch(identityProvider(repoPath));
    final busy = ref.watch(repoActionsProvider(repoPath));
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final value = identity.value;
    if (value == null) return const SizedBox.shrink();

    if (!value.isComplete) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text('Who’s committing?', style: theme.textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Tooltip(
                    message:
                        'Saved in this repository’s own settings (.git/config). '
                        'Your other projects aren’t affected.',
                    child: Icon(
                      Icons.folder_outlined,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Every commit is signed with a name and email. Tell Git who you '
                'are — it’s saved only for this repository.',
                style: muted,
              ),
              const SizedBox(height: 14),
              IdentityForm(
                repoPath: repoPath,
                initial: value,
                busy: busy == GitAction.identity,
                submitLabel: 'Save for this repository',
                onSaved: (message) =>
                    showFriendlySnack(context, message: message),
              ),
            ],
          ),
        ),
      );
    }

    final name = value.name!.trim();
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                initial,
                style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Committing as $name',
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${value.email} · ${_scopeLabel(value)}',
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: busy != null
                  ? null
                  : () async {
                      final message = await showIdentityDialog(
                        context,
                        repoPath: repoPath,
                      );
                      if (message != null && context.mounted) {
                        showFriendlySnack(context, message: message);
                      }
                    },
              child: const Text('Change…'),
            ),
          ],
        ),
      ),
    );
  }

  static String _scopeLabel(GitIdentity i) {
    if (i.isLocal) return 'set for this repository';
    if (i.nameScope == 'local' || i.emailScope == 'local') {
      return 'partly set for this repository';
    }
    return switch (i.nameScope) {
      'global' => 'from your Git settings',
      'system' => 'from this computer’s Git settings',
      _ => 'from your Git settings',
    };
  }
}

/// Asks for name + email and saves them for [repoPath] only.
/// Returns the success message, or null if cancelled.
Future<String?> showIdentityDialog(
  BuildContext context, {
  required String repoPath,
  String? reason,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _IdentityDialog(repoPath: repoPath, reason: reason),
  );
}

class _IdentityDialog extends ConsumerWidget {
  const _IdentityDialog({required this.repoPath, this.reason});

  final String repoPath;
  final String? reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final identity = ref.watch(identityProvider(repoPath));
    final busy = ref.watch(repoActionsProvider(repoPath)) == GitAction.identity;
    return AlertDialog(
      title: const Text('Who’s committing?'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reason ??
                  'This name and email label your commits in this repository. '
                      'They’re saved only here — other projects keep their own.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (identity.value == null)
              const LinearProgressIndicator()
            else
              IdentityForm(
                repoPath: repoPath,
                initial: identity.value!,
                busy: busy,
                submitLabel: 'Save',
                onCancel: () => Navigator.pop(context),
                onSaved: (message) => Navigator.pop(context, message),
              ),
          ],
        ),
      ),
    );
  }
}

/// Name + email fields with a "Use my GitHub details" shortcut.
class IdentityForm extends ConsumerStatefulWidget {
  const IdentityForm({
    super.key,
    required this.repoPath,
    required this.initial,
    required this.busy,
    required this.submitLabel,
    required this.onSaved,
    this.onCancel,
  });

  final String repoPath;
  final GitIdentity initial;
  final bool busy;
  final String submitLabel;
  final ValueChanged<String> onSaved;
  final VoidCallback? onCancel;

  @override
  ConsumerState<IdentityForm> createState() => _IdentityFormState();
}

class _IdentityFormState extends ConsumerState<IdentityForm> {
  late final TextEditingController _name;
  late final TextEditingController _email;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial.name ?? '');
    _email = TextEditingController(text: widget.initial.email ?? '');
    // Friendly default: prefill from the connected GitHub account.
    final account = ref.read(accountProvider).value;
    if (account != null) _fillFromAccount(account, onlyEmpty: true);
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  void _fillFromAccount(ProviderAccount account, {bool onlyEmpty = false}) {
    final name = account.displayName?.trim().isNotEmpty == true
        ? account.displayName!.trim()
        : account.username;
    final email = account.noreplyEmail;
    if (!onlyEmpty || _name.text.trim().isEmpty) _name.text = name;
    if (email != null && (!onlyEmpty || _email.text.trim().isEmpty)) {
      _email.text = email;
    }
    // Not during initState — the first build picks the values up anyway.
    if (!onlyEmpty) setState(() => _error = null);
  }

  Future<void> _save() async {
    final problem = GitService.validateIdentity(_name.text, _email.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() => _error = null);
    final outcome = await ref
        .read(repoActionsProvider(widget.repoPath).notifier)
        .setIdentity(_name.text, _email.text);
    if (!mounted) return;
    if (outcome.ok) {
      widget.onSaved(outcome.message);
    } else {
      setState(() => _error = outcome.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = ref.watch(accountProvider).value;
    final usingNoreply =
        _email.text.trim().toLowerCase().endsWith('@users.noreply.github.com');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (account != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: ActionChip(
              avatar: const Icon(Icons.hub_outlined, size: 16),
              label: Text('Use my GitHub details (@${account.username})'),
              onPressed: widget.busy ? null : () => _fillFromAccount(account),
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _name,
          enabled: !widget.busy,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Your name',
            hintText: 'e.g. Ada Lovelace',
            prefixIcon: Icon(Icons.person_outline),
          ),
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _email,
          enabled: !widget.busy,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Email',
            hintText: 'you@example.com',
            prefixIcon: const Icon(Icons.alternate_email_rounded),
            helperText: usingNoreply
                ? 'GitHub’s private address — your real email stays hidden.'
                : account != null
                ? 'Tip: your GitHub no-reply address keeps your real email private.'
                : 'Use the email of your Git hosting account so commits link to you.',
            helperMaxLines: 2,
          ),
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => _save(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (widget.onCancel != null) ...[
              TextButton(
                onPressed: widget.busy ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
            ],
            FilledButton.icon(
              onPressed: widget.busy ? null : _save,
              icon: widget.busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
              label: Text(widget.submitLabel),
            ),
          ],
        ),
      ],
    );
  }
}
