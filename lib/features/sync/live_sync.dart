import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/provider_cache.dart';
import '../../services/git/git_models.dart';
import '../../services/service_providers.dart';
import '../dashboard/tracked_repos_controller.dart';
import '../repository/repo_actions_controller.dart';
import '../settings/settings_controller.dart';

// -----------------------------------------------------------------------------
// 1. Files on disk → live status
// -----------------------------------------------------------------------------

/// Watches a connected folder and refreshes Gitty the moment files change —
/// new, edited, deleted, or git commands run from a terminal/IDE.
///
/// Events are batched (a short pause, but never more than ~1.5 s of delay)
/// so a flood like `npm install` costs a handful of refreshes, not thousands.
/// Changes inside folders the root `.gitignore` ignores outright
/// (`node_modules/`, `build/`, …) are skipped, since they can't change
/// `git status`. Watch it from any widget that shows the repository; it
/// stops when no one is looking.
final repoWatchProvider = Provider.autoDispose.family<void, String>(
  (ref, path) => _watchRepository(ref, path, gitOnly: false),
);

/// Lighter watcher for the dashboard cards: only Git's own bookkeeping
/// (commits, branch switches, staging, fetches — from Gitty, a terminal or
/// an IDE), not every file in the working tree. Plain file edits show up
/// when you come back to Gitty or open the repository.
final repoGitWatchProvider = Provider.autoDispose.family<void, String>((
  ref,
  path,
) {
  // Setting a watcher up isn't free; keep it while a card is briefly off
  // screen.
  ref.cacheFor(const Duration(minutes: 2));
  _watchRepository(ref, path, gitOnly: true);
});

void _watchRepository(Ref ref, String path, {required bool gitOnly}) {
  final dir = Directory(path);
  if (!dir.existsSync()) return;

  // Worktrees and submodules keep `.git` as a file; watch the whole folder.
  final gitDir = Directory(p.join(path, '.git'));
  final watchGitDirOnly = gitOnly && gitDir.existsSync();
  final root = watchGitDirOnly ? gitDir.path : path;
  final prefix = root.endsWith(p.separator) ? root : '$root${p.separator}';
  var ignored = watchGitDirOnly
      ? _IgnoredFolders.none
      : _IgnoredFolders.read(path);

  Timer? debounce;
  DateTime? firstPending;
  var refsChanged = false;
  var configChanged = false;

  void flush() {
    debounce?.cancel();
    debounce = null;
    firstPending = null;
    ref.invalidate(repoSnapshotProvider(path));
    if (refsChanged) {
      ref.invalidate(branchesProvider(path));
      ref.invalidate(branchTreeProvider(path));
      ref.invalidate(parentSyncProvider(path));
    }
    if (configChanged) {
      ref.invalidate(remotesProvider(path));
      ref.invalidate(remoteHostProvider(path));
      ref.invalidate(identityProvider(path));
    }
    refsChanged = false;
    configChanged = false;
  }

  void onEvent(FileSystemEvent event) {
    final full = event.path;
    // Cheap path math first: this runs for every single file event.
    var rel = full == root
        ? ''
        : full.startsWith(prefix)
        ? full.substring(prefix.length)
        : p.relative(full, from: root);
    if (Platform.isWindows) rel = rel.replaceAll(r'\', '/');

    // Path inside `.git`, or null for a working-tree file.
    String? inner;
    if (watchGitDirOnly) {
      inner = rel;
    } else if (rel == '.git' || rel.startsWith('.git/')) {
      inner = rel.length > 5 ? rel.substring(5) : '';
    } else if (rel == '.gitignore') {
      ignored = _IgnoredFolders.read(path);
    } else if (ignored.covers(rel)) {
      return;
    }

    if (inner != null) {
      // Git's own bookkeeping churns constantly; only a few files matter.
      if (inner.startsWith('objects/') ||
          inner.startsWith('logs/') ||
          inner.endsWith('.lock') ||
          inner.startsWith('gitty-')) {
        return;
      }
      if (inner == 'config') configChanged = true;
      if (inner == 'HEAD' ||
          inner.startsWith('refs/') ||
          inner == 'packed-refs' ||
          inner == 'FETCH_HEAD' ||
          inner == 'ORIG_HEAD' ||
          inner == 'MERGE_HEAD') {
        refsChanged = true;
      }
    }
    final now = DateTime.now();
    firstPending ??= now;
    debounce?.cancel();
    if (now.difference(firstPending!) > const Duration(milliseconds: 1500)) {
      flush();
    } else {
      debounce = Timer(const Duration(milliseconds: 300), flush);
    }
  }

  StreamSubscription<FileSystemEvent>? subscription;
  Timer? poll;
  try {
    // Recursive watching isn't available on Linux; poll there instead.
    subscription = Directory(root)
        .watch(recursive: !Platform.isLinux)
        .listen(onEvent, onError: (Object _) {});
  } catch (_) {
    // Unsupported file system (e.g. some network drives) — poll below.
  }
  if (subscription == null || Platform.isLinux) {
    // The dashboard's light watcher can afford to poll far less often.
    poll = Timer.periodic(
      Duration(seconds: watchGitDirOnly ? 30 : 4),
      (_) => flush(),
    );
  }

  ref.onDispose(() {
    unawaited(subscription?.cancel());
    debounce?.cancel();
    poll?.cancel();
  });
}

/// Folders the repository's root `.gitignore` ignores outright, by plain
/// name (`node_modules/`, `/build`, `.dart_tool`, …). Nothing inside them
/// can change `git status`, so the watcher skips their events without
/// asking Git. Patterns with wildcards or inner slashes are left alone —
/// those folders are simply not skipped.
class _IgnoredFolders {
  const _IgnoredFolders(this.anywhere, this.atRoot);

  static const none = _IgnoredFolders(<String>{}, <String>{});

  /// `name` / `name/`: ignored at any depth.
  final Set<String> anywhere;

  /// `/name` / `/name/`: ignored only at the top level.
  final Set<String> atRoot;

  static final _plain = RegExp(r'^(!?)(/?)([A-Za-z0-9._-]+)/?$');

  static _IgnoredFolders read(String repo) {
    try {
      final file = File(p.join(repo, '.gitignore'));
      if (!file.existsSync()) return none;
      final anywhere = <String>{};
      final atRoot = <String>{};
      final reincluded = <String>{};
      for (final line in file.readAsLinesSync()) {
        final m = _plain.firstMatch(line.trim());
        if (m == null) continue;
        final name = m.group(3)!;
        if (name == '.' || name == '..' || name == '.git') continue;
        if (m.group(1)!.isNotEmpty) {
          reincluded.add(name); // `!name` — be safe, never skip it
        } else if (m.group(2)!.isEmpty) {
          anywhere.add(name);
        } else {
          atRoot.add(name);
        }
      }
      anywhere.removeAll(reincluded);
      atRoot.removeAll(reincluded);
      return _IgnoredFolders(anywhere, atRoot);
    } catch (_) {
      return none;
    }
  }

  bool covers(String rel) {
    if (anywhere.isEmpty && atRoot.isEmpty) return false;
    final parts = rel.split('/');
    return atRoot.contains(parts.first) || parts.any(anywhere.contains);
  }
}

/// Refreshes every repository when you come back to Gitty (e.g. after
/// working in your editor or terminal). Watched once by the home shell.
final appResumeRefreshProvider = Provider<void>((ref) {
  final listener = AppLifecycleListener(
    onResume: () => ref.invalidate(repoSnapshotProvider),
  );
  ref.onDispose(listener.dispose);
});

// -----------------------------------------------------------------------------
// 2. Origin → notices
// -----------------------------------------------------------------------------

enum RemoteNoticeKind {
  /// Someone pushed to the branch you're on.
  yourBranch,

  /// The branch yours grew from moved ahead (e.g. main).
  parentBranch,

  /// A teammate published a new branch.
  newBranch,

  /// Anything else that moved.
  other,
}

class RemoteNotice {
  const RemoteNotice({
    required this.id,
    required this.repoPath,
    required this.kind,
    required this.update,
    required this.at,
    this.yourBranch,
    this.title,
  });

  final int id;
  final String repoPath;
  final RemoteNoticeKind kind;
  final RemoteUpdate update;
  final DateTime at;

  /// The branch you were on when this arrived.
  final String? yourBranch;

  /// Title shown in Gitty (custom name, if set).
  final String? title;

  String get repoName => title ?? p.basename(repoPath);

  /// Worth a pop-up (not just a quiet note).
  bool get isImportant =>
      kind == RemoteNoticeKind.yourBranch ||
      kind == RemoteNoticeKind.parentBranch;

  /// "Ana and Bob", "Ana and 3 others", "someone".
  String get who {
    final a = update.authors;
    if (a.isEmpty) return 'Someone';
    if (a.length == 1) return a.first;
    if (a.length == 2) return '${a[0]} and ${a[1]}';
    return '${a[0]} and ${a.length - 1} others';
  }

  String get changes => update.newCommits == 1
      ? '1 new change'
      : '${update.newCommits} new changes';

  /// One friendly sentence.
  String get message => switch (kind) {
    RemoteNoticeKind.yourBranch =>
      update.rewritten
          ? '$who rewrote “${update.branch}” in $repoName. Pull carefully.'
          : '$who pushed $changes to “${update.branch}” in $repoName — pull to get them.',
    RemoteNoticeKind.parentBranch =>
      '$who pushed $changes to “${update.branch}” in $repoName — the branch '
          '“${yourBranch ?? 'yours'}” grew from. Time to bring them in.',
    RemoteNoticeKind.newBranch =>
      '$who published a new branch “${update.branch}” in $repoName.',
    RemoteNoticeKind.other =>
      '“${update.branch}” in $repoName got $changes.',
  };
}

/// Everything that arrived from remotes while Gitty was open.
class RemoteUpdatesController extends Notifier<List<RemoteNotice>> {
  final _inFlight = <String>{};
  var _nextId = 1;

  @override
  List<RemoteNotice> build() => const [];

  /// Fetches [repo] and records what changed. Safe to call often.
  Future<void> check(String repo) async {
    if (!_inFlight.add(repo)) return;
    try {
      final git = ref.read(gitServiceProvider);
      if (!Directory(repo).existsSync() || !await git.isRepository(repo)) {
        return;
      }
      if ((await git.remotes(repo)).isEmpty) return;

      final updates = await git.fetchWithUpdates(repo);
      if (!ref.mounted) return;
      ref.invalidate(repoSnapshotProvider(repo));
      ref.invalidate(branchesProvider(repo));
      ref.invalidate(branchTreeProvider(repo));
      ref.invalidate(parentSyncProvider(repo));
      if (updates.isEmpty) return;

      final branch = await git.currentBranch(repo);
      String? upstream;
      String? parentRemote;
      if (branch != null) {
        final u = await git.upstreamOf(repo, branch);
        upstream = u;
        final parent = await git.branchParent(repo, branch);
        if (parent != null) parentRemote = 'origin/$parent';
      }

      final now = DateTime.now();
      final fresh = [
        for (final u in updates)
          RemoteNotice(
            id: _nextId++,
            repoPath: repo,
            at: now,
            update: u,
            yourBranch: branch,
            title: ref
                .read(trackedReposProvider)
                .where((r) => r.path == repo)
                .firstOrNull
                ?.title,
            kind: u.remoteRef == upstream
                ? RemoteNoticeKind.yourBranch
                : u.remoteRef == parentRemote
                ? RemoteNoticeKind.parentBranch
                : u.isNewBranch
                ? RemoteNoticeKind.newBranch
                : RemoteNoticeKind.other,
          ),
      ];
      if (!ref.mounted) return;
      final replaced = {for (final n in fresh) '${n.repoPath}|${n.update.remoteRef}'};
      state = [
        ...state.where((n) => !replaced.contains('${n.repoPath}|${n.update.remoteRef}')),
        ...fresh,
      ];
    } catch (_) {
      // Offline, no credentials, … — the next check will try again.
    } finally {
      _inFlight.remove(repo);
    }
  }

  void dismiss(int id) => state = state.where((n) => n.id != id).toList();

  void dismissFor(String repo, String remoteRef) => state = state
      .where((n) => n.repoPath != repo || n.update.remoteRef != remoteRef)
      .toList();
}

final remoteUpdatesProvider =
    NotifierProvider<RemoteUpdatesController, List<RemoteNotice>>(
      RemoteUpdatesController.new,
    );

/// While a repository is open: check the remote right away and then every
/// minute, so teammates' pushes show up quickly. (Other repositories are
/// checked on the slower background schedule from Settings.)
final liveRemoteSyncProvider = Provider.autoDispose.family<void, String>((
  ref,
  path,
) {
  final enabled = ref.watch(
    settingsControllerProvider.select((s) => s.autoFetch),
  );
  if (!enabled) return;
  final controller = ref.read(remoteUpdatesProvider.notifier);
  final first = Timer(const Duration(seconds: 2), () => controller.check(path));
  final every = Timer.periodic(
    const Duration(minutes: 1),
    (_) => controller.check(path),
  );
  ref.onDispose(() {
    first.cancel();
    every.cancel();
  });
});

/// How the current branch compares with the branch it grew from.
final parentSyncProvider = FutureProvider.autoDispose
    .family<ParentSync?, String>((ref, path) {
      ref.watch(repoSnapshotProvider(path));
      return ref.watch(gitServiceProvider).parentSync(path);
    });
