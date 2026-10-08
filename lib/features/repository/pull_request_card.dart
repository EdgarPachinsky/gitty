import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/gitty_exception.dart';
import '../../core/widgets/state_views.dart';
import '../../services/ai/ai_text.dart';
import '../../services/ai/change_prompts.dart';
import '../../services/auth/github_pulls.dart';
import '../../services/git/git_models.dart';
import '../../services/service_providers.dart';
import '../account/account_controller.dart';
import '../dashboard/tracked_repos_controller.dart';
import 'repo_actions_controller.dart';

// --- Data ----------------------------------------------------------------------------

enum PrPanelKind {
  /// The branch isn't on GitHub yet — publish it first.
  notPublished,
  notConnected,
  canCreate,
  exists,

  /// Couldn't ask GitHub (offline, no access…); [PrPanel.error] says why.
  error,
}

class PrPanel {
  const PrPanel({
    required this.kind,
    required this.owner,
    required this.repo,
    required this.branch,
    required this.base,
    required this.compareUrl,
    this.pr,
    this.checks,
    this.reviews,
    this.error,
  });

  final PrPanelKind kind;
  final String owner;
  final String repo;

  /// Branch name online (the pull request's "head").
  final String branch;

  /// Suggested target branch (where it grew from, or the default branch).
  final String base;

  /// github.com page to open a pull request in the browser.
  final Uri compareUrl;
  final PullRequestInfo? pr;
  final PrChecks? checks;
  final PrReviews? reviews;
  final String? error;
}

/// Pull request status for the current branch — null when it doesn't apply
/// (not GitHub, branch not online yet, or on the default branch). Checked
/// again every 90 seconds while shown, so CI results update by themselves.
final pullRequestPanelProvider = FutureProvider.autoDispose
    .family<PrPanel?, String>((ref, path) async {
      final timer = Timer(const Duration(seconds: 90), ref.invalidateSelf);
      ref.onDispose(timer.cancel);

      final (branch, upstream, _) = ref.watch(
        repoSnapshotProvider(path).select(
          (s) => (
            s.value?.status.branch,
            s.value?.status.upstream,
            s.value?.status.headOid,
          ),
        ),
      );
      if (branch == null) return null; // not on a branch
      final host = await ref.watch(remoteHostProvider(path).future);
      final web = host?.webUrl;
      if (host == null || host.kind != RemoteHostKind.github || web == null) {
        return null;
      }
      final parts = web.pathSegments.where((s) => s.isNotEmpty).toList();
      if (parts.length < 2) return null;
      final (owner, repo) = (parts[0], parts[1]);

      final slash = upstream?.indexOf('/') ?? -1;
      final remote = slash < 0 ? 'origin' : upstream!.substring(0, slash);
      final head = slash < 0 ? branch : upstream!.substring(slash + 1);

      final git = ref.watch(gitServiceProvider);
      final online = await git.remoteBranchNames(path, remote: remote);
      // origin/HEAD isn't always set (e.g. a repo created locally, then
      // pushed); fall back to the usual names.
      final defaultBranch =
          await git.remoteDefaultBranch(path, remote: remote) ??
          (online.contains('main')
              ? 'main'
              : online.contains('master')
              ? 'master'
              : 'main');
      if (head == defaultBranch) return null;
      final parent = await git.recordedParent(path, branch);
      final base = parent != null && parent != head && online.contains(parent)
          ? parent
          : defaultBranch;
      final compareUrl = web.replace(
        path: '${web.path}/compare/$base...$head',
        queryParameters: {'expand': '1'},
      );

      PrPanel panel(
        PrPanelKind kind, {
        PullRequestInfo? pr,
        PrChecks? checks,
        PrReviews? reviews,
        String? error,
      }) =>
          PrPanel(
            kind: kind,
            owner: owner,
            repo: repo,
            branch: head,
            base: base,
            compareUrl: compareUrl,
            pr: pr,
            checks: checks,
            reviews: reviews,
            error: error,
          );

      // Not online yet: a pull request needs the branch on GitHub first.
      if (upstream == null) return panel(PrPanelKind.notPublished);

      final account = await ref.watch(accountProvider.future);
      if (account == null || account.isDemo) {
        return panel(PrPanelKind.notConnected);
      }
      final pulls = ref.watch(gitHubPullsProvider);
      try {
        final pr = await pulls.forBranch(owner, repo, head);
        if (pr == null) return panel(PrPanelKind.canCreate);
        if (!pr.isOpen) return panel(PrPanelKind.exists, pr: pr);
        final results = await Future.wait<Object>([
          pulls.checks(owner, repo, pr.headSha),
          pulls.reviews(owner, repo, pr.number),
        ]);
        return panel(
          PrPanelKind.exists,
          pr: pr,
          checks: results[0] as PrChecks,
          reviews: results[1] as PrReviews,
        );
      } catch (e) {
        final error = toGittyException(e);
        return panel(
          PrPanelKind.error,
          error: [error.message, if (error.hint != null) error.hint!].join(' '),
        );
      }
    });

// --- Card -------------------------------------------------------------------------------

/// Shown on the repository screen for branches that are online on GitHub:
/// open a pull request, or see how the open one is doing.
class PullRequestCard extends ConsumerWidget {
  const PullRequestCard({
    super.key,
    required this.repoPath,
    required this.status,
    required this.onPublish,
  });

  final String repoPath;
  final RepoStatus status;

  /// Puts the branch on GitHub (the repository screen's Publish).
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(pullRequestPanelProvider(repoPath));
    final data = panel.value;
    if (data == null) {
      // Loading for the first time, errors (e.g. offline) or not relevant:
      // stay out of the way.
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    void open(Uri url) => ref.read(systemLauncherProvider).openUrl(url);

    Widget row({
      required IconData icon,
      required String title,
      required String text,
      required List<Widget> buttons,
      Color? iconColor,
    }) => Row(
      children: [
        Icon(icon, color: iconColor ?? scheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              Text(text, style: muted),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ...buttons,
      ],
    );

    final Widget content;
    switch (data.kind) {
      case PrPanelKind.notPublished:
        content = row(
          icon: Icons.rate_review_outlined,
          title: 'Want teammates to review “${data.branch}”?',
          text:
              'It isn’t on GitHub yet. Publish it first, then you can open a '
              'pull request right here.',
          buttons: [
            FilledButton.tonalIcon(
              onPressed: onPublish,
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              label: const Text('Publish'),
            ),
          ],
        );
      case PrPanelKind.error:
        content = row(
          icon: Icons.cloud_off_outlined,
          iconColor: scheme.error,
          title: 'Couldn’t check pull requests for “${data.branch}”',
          text: data.error ?? '',
          buttons: [
            IconButton(
              tooltip: 'Try again',
              onPressed: () =>
                  ref.invalidate(pullRequestPanelProvider(repoPath)),
              icon: const Icon(Icons.refresh_rounded),
            ),
            OutlinedButton.icon(
              onPressed: () => open(data.compareUrl),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('Open on GitHub'),
            ),
          ],
        );
      case PrPanelKind.notConnected || PrPanelKind.canCreate:
        final connected = data.kind == PrPanelKind.canCreate;
        content = Row(
          children: [
            Icon(Icons.rate_review_outlined, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ready for others to look at “${data.branch}”?',
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    connected
                        ? 'Open a pull request so teammates can review it '
                              'before it goes into “${data.base}”.'
                        : 'Open a pull request on GitHub. (Connect GitHub in '
                              'Settings to do it right here.)',
                    style: muted,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (connected)
              FilledButton.icon(
                onPressed: () => showCreatePullRequestDialog(
                  context,
                  repoPath: repoPath,
                  panel: data,
                  status: status,
                ),
                icon: const Icon(Icons.add_comment_outlined, size: 18),
                label: const Text('Open a pull request'),
              )
            else
              OutlinedButton.icon(
                onPressed: () => open(data.compareUrl),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open on GitHub'),
              ),
          ],
        );
      case PrPanelKind.exists:
        final pr = data.pr!;
        content = _ExistingPr(
          pr: pr,
          checks: data.checks,
          reviews: data.reviews,
          onOpen: () => open(pr.url),
          onRefresh: () => ref.invalidate(pullRequestPanelProvider(repoPath)),
        );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(padding: const EdgeInsets.all(16), child: content),
      ),
    );
  }
}

class _ExistingPr extends StatelessWidget {
  const _ExistingPr({
    required this.pr,
    required this.checks,
    required this.reviews,
    required this.onOpen,
    required this.onRefresh,
  });

  final PullRequestInfo pr;
  final PrChecks? checks;
  final PrReviews? reviews;
  final VoidCallback onOpen;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    final (stateText, stateColor, stateIcon) = pr.merged
        ? ('Merged', Colors.purple, Icons.merge_rounded)
        : !pr.isOpen
        ? ('Closed', scheme.error, Icons.block_rounded)
        : pr.draft
        ? ('Draft', scheme.outline, Icons.edit_note_rounded)
        : ('Open', Colors.green.shade600, Icons.rate_review_outlined);

    final notes = <(IconData, String, Color?)>[];
    if (pr.merged) {
      notes.add((
        Icons.celebration_outlined,
        'Merged into “${pr.base}”. Switch to “${pr.base}” and pull to get it there too.',
        null,
      ));
    } else if (pr.isOpen) {
      final c = checks;
      if (c != null && c.total > 0) {
        notes.add(
          c.failed > 0
              ? (Icons.cancel_outlined, '${c.failed} of ${c.total} checks failed', scheme.error)
              : c.running > 0
              ? (Icons.hourglass_top_rounded, '${c.running} of ${c.total} checks still running', null)
              : (Icons.check_circle_outline, 'All ${c.total} checks passed', Colors.green.shade600),
        );
      }
      final r = reviews;
      if (r != null && r.changesRequestedBy.isNotEmpty) {
        notes.add((
          Icons.feedback_outlined,
          'Changes requested by ${r.changesRequestedBy.join(', ')}',
          scheme.error,
        ));
      } else if (r != null && r.approvedBy.isNotEmpty) {
        notes.add((
          Icons.thumb_up_alt_outlined,
          'Approved by ${r.approvedBy.join(', ')}',
          Colors.green.shade600,
        ));
      } else if (pr.requestedReviewers.isNotEmpty) {
        notes.add((
          Icons.schedule_rounded,
          'Waiting for a review from ${pr.requestedReviewers.join(', ')}',
          null,
        ));
      } else {
        notes.add((Icons.person_search_outlined, 'No reviews yet', null));
      }
      if (pr.mergeableState == 'dirty') {
        notes.add((
          Icons.call_merge_rounded,
          'Clashes with “${pr.base}” — bring “${pr.base}” into your branch and '
              'resolve them first',
          scheme.error,
        ));
      } else if (pr.mergeableState == 'behind') {
        notes.add((
          Icons.update_rounded,
          '“${pr.base}” has moved on — consider bringing it in',
          null,
        ));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(stateIcon, color: stateColor),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: stateColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                stateText,
                style: theme.textTheme.labelMedium?.copyWith(color: stateColor),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '#${pr.number} ${pr.title}',
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Check again',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 18),
            ),
            OutlinedButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Open on GitHub'),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 34, top: 2),
          child: Text('“${pr.head}” → “${pr.base}”', style: muted),
        ),
        if (notes.isNotEmpty) const SizedBox(height: 8),
        for (final (icon, text, color) in notes)
          Padding(
            padding: const EdgeInsets.only(left: 34, top: 4),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color ?? scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(color: color),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// --- "Open a pull request" ---------------------------------------------------------------

Future<void> showCreatePullRequestDialog(
  BuildContext context, {
  required String repoPath,
  required PrPanel panel,
  required RepoStatus status,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _CreatePrDialog(repoPath: repoPath, panel: panel, status: status),
);

class _CreatePrDialog extends ConsumerStatefulWidget {
  const _CreatePrDialog({
    required this.repoPath,
    required this.panel,
    required this.status,
  });

  final String repoPath;
  final PrPanel panel;
  final RepoStatus status;

  @override
  ConsumerState<_CreatePrDialog> createState() => _CreatePrDialogState();
}

class _CreatePrDialogState extends ConsumerState<_CreatePrDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  late String _base = widget.panel.base;
  bool _draft = false;
  bool _writing = false;
  bool _creating = false;
  bool _titleTouched = false;
  String? _error;
  List<String> _bases = const [];
  (List<String>, String, String)? _since; // subjects, log, stat

  @override
  void initState() {
    super.initState();
    _loadBases();
    _loadChanges();
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _loadBases() async {
    final names = await ref
        .read(gitServiceProvider)
        .remoteBranchNames(widget.repoPath);
    if (mounted) {
      setState(
        () => _bases = names.where((n) => n != widget.panel.branch).toList(),
      );
    }
  }

  /// Commits between the target and this branch → default title.
  Future<void> _loadChanges() async {
    try {
      final since = await ref
          .read(gitServiceProvider)
          .changesSince(widget.repoPath, 'origin/$_base');
      if (!mounted) return;
      setState(() => _since = since);
      if (!_titleTouched) {
        final subjects = since.$1;
        setState(
          () => _title.text = subjects.length == 1
              ? subjects.first
              : _humanize(widget.panel.branch),
        );
      }
    } catch (_) {
      if (mounted && !_titleTouched && _title.text.isEmpty) {
        setState(() => _title.text = _humanize(widget.panel.branch));
      }
    }
  }

  /// "feature/login-form" → "Login form"
  static String _humanize(String branch) {
    final last = branch.split('/').last.replaceAll(RegExp(r'[-_]+'), ' ').trim();
    return last.isEmpty ? branch : last[0].toUpperCase() + last.substring(1);
  }

  Future<void> _write() async {
    final since = _since;
    if (since == null) return;
    setState(() {
      _writing = true;
      _error = null;
    });
    try {
      final ai = ref.read(aiTextProvider);
      final log = since.$2.length > ai.maxInputChars
          ? since.$2.substring(0, max(0, ai.maxInputChars))
          : since.$2;
      final (system, prompt) = pullRequestPrompt(
        branch: widget.panel.branch,
        base: _base,
        log: log,
        stat: since.$3,
      );
      final text = await ai.complete(
        system: system,
        prompt: prompt,
        onText: (t) {
          if (mounted) _body.text = t;
        },
      );
      if (mounted) _body.text = stripCodeFence(stripThinking(text)).trim();
    } catch (e) {
      if (mounted) setState(() => _error = toGittyException(e).message);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final pr = await ref.read(gitHubPullsProvider).create(
        owner: widget.panel.owner,
        repo: widget.panel.repo,
        head: widget.panel.branch,
        base: _base,
        title: title,
        body: _body.text.trim(),
        draft: _draft,
      );
      ref.invalidate(pullRequestPanelProvider(widget.repoPath));
      if (!mounted) return;
      Navigator.pop(context);
      showFriendlySnack(
        context,
        message: 'Opened pull request #${pr.number}. Teammates can review it now.',
      );
    } catch (e) {
      if (mounted) setState(() => _error = toGittyException(e).message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final aiReady = ref.watch(aiTextProvider).unavailableReason == null;
    final notPushed = widget.status.ahead;
    final commits = _since?.$1.length;

    return AlertDialog(
      title: const Text('Open a pull request'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Asks your teammates to review “${widget.panel.branch}” and '
                'merge it into the branch you pick.',
                style: muted,
              ),
              if (notPushed > 0) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'You have $notPushed commit${notPushed == 1 ? '' : 's'} '
                    'not pushed yet — they won’t be in the pull request until '
                    'you push.',
                    style: TextStyle(color: scheme.onTertiaryContainer),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              DropdownMenu<String>(
                key: ValueKey(_bases.length),
                initialSelection: _base,
                expandedInsets: EdgeInsets.zero,
                enableFilter: true,
                requestFocusOnTap: true,
                menuHeight: 300,
                label: const Text('Merge into'),
                leadingIcon: const Icon(Icons.call_merge_rounded, size: 18),
                dropdownMenuEntries: [
                  for (final b in {..._bases, _base})
                    DropdownMenuEntry(value: b, label: b),
                ],
                onSelected: (v) {
                  if (v == null || v == _base) return;
                  setState(() {
                    _base = v;
                    _since = null;
                  });
                  _loadChanges();
                },
              ),
              if (commits != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(
                    commits == 0
                        ? 'No commits to review compared with “$_base”.'
                        : '$commits commit${commits == 1 ? '' : 's'} will be '
                              'reviewed.',
                    style: muted,
                  ),
                ),
              const SizedBox(height: 14),
              TextField(
                controller: _title,
                onChanged: (_) => setState(() => _titleTouched = true),
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _body,
                minLines: 6,
                maxLines: 14,
                decoration: InputDecoration(
                  labelText: 'Description',
                  alignLabelWithHint: true,
                  hintText: 'What changed and why? How can someone test it?',
                  suffixIcon: !aiReady
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Align(
                            alignment: Alignment.topRight,
                            widthFactor: 1,
                            heightFactor: 1,
                            child: _writing
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : IconButton(
                                    tooltip: 'Write it with AI',
                                    onPressed: _since == null ? null : _write,
                                    icon: const Icon(
                                      Icons.auto_awesome_outlined,
                                    ),
                                  ),
                          ),
                        ),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _draft,
                onChanged: (v) => setState(() => _draft = v ?? false),
                title: const Text('Draft'),
                subtitle: Text(
                  'Still working on it — reviewers know it’s not ready yet.',
                  style: muted,
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _creating || _title.text.trim().isEmpty ? null : _create,
          icon: _creating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_rounded, size: 18),
          label: const Text('Open pull request'),
        ),
      ],
    );
  }
}
