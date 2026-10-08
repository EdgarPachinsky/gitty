import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/gitty_exception.dart';
import '../../core/utils/provider_cache.dart';
import '../../core/utils/task_limiter.dart';
import '../../services/ai/commit_style.dart';
import '../../services/git/git_models.dart';
import '../../services/service_providers.dart';
import '../../services/storage/repo_repository.dart';
import '../settings/settings_controller.dart';
import '../sync/live_sync.dart';

/// The list of repositories the user added to Gitty.
class TrackedReposController extends Notifier<List<TrackedRepo>> {
  @override
  List<TrackedRepo> build() =>
      _sorted(ref.watch(repoRepositoryProvider).loadAll());

  RepoRepository get _repo => ref.read(repoRepositoryProvider);

  bool contains(String path) => state.any((r) => r.path == path);

  /// Adds a folder to Gitty. Any folder works — empty or not, with or
  /// without Git. If it's inside an existing repository we track that
  /// repository's root; otherwise the folder itself (the repository screen
  /// then offers to initialize Git). Returns the tracked repo.
  Future<TrackedRepo> addFolder(String path) async {
    if (!Directory(path).existsSync()) {
      throw GittyException(
        "That folder doesn't seem to exist.",
        hint: 'Pick another folder and try again.',
        details: path,
      );
    }
    final root = await ref.read(gitServiceProvider).findRepositoryRoot(path);
    return _add(root ?? p.normalize(path));
  }

  /// Adds already-verified repository roots (e.g. from the scanner or clone).
  Future<void> addRoots(Iterable<String> roots) async {
    for (final root in roots) {
      await _add(root);
    }
  }

  Future<TrackedRepo> _add(String root) async {
    final existing = state.where((r) => r.path == root).firstOrNull;
    if (existing != null) return existing;
    // Once the user has arranged the cards, new ones go to the end.
    final orders = state.map((r) => r.sortOrder).whereType<int>();
    final repo = TrackedRepo(
      path: root,
      addedAt: DateTime.now(),
      sortOrder: orders.isEmpty ? null : orders.reduce(max) + 1,
    );
    await _repo.save(repo);
    state = _sorted([...state, repo]);
    return repo;
  }

  Future<void> remove(String path) async {
    await _repo.remove(path);
    state = state.where((r) => r.path != path).toList();
  }

  Future<void> setPreferredStyle(String path, CommitStyle style) =>
      _modify(path, (r) => r.copyWith(preferredCommitStyle: style));

  /// Sets the title shown in Gitty (null or empty = use the folder name).
  Future<void> rename(String path, String? title) async {
    final t = title?.trim() ?? '';
    await _modify(
      path,
      (r) => t.isEmpty || t == r.name
          ? r.copyWith(clearDisplayName: true)
          : r.copyWith(displayName: t),
    );
    state = _sorted([...state]);
  }

  /// Pins a repository to the top section of the list, or unpins it.
  Future<void> togglePin(String path) async {
    final current = state.where((r) => r.path == path).firstOrNull;
    if (current == null) return;
    await _modify(path, (r) => r.copyWith(pinned: !current.pinned));
  }

  /// Drag-and-drop on the dashboard: moves [path] into [target]'s place
  /// (after it when moving down, before it when moving up) and remembers
  /// the new order.
  Future<void> reorder(String path, String target) async {
    final list = [...state];
    final from = list.indexWhere((r) => r.path == path);
    final to = list.indexWhere((r) => r.path == target);
    if (from < 0 || to < 0 || from == to) return;
    list.insert(to, list.removeAt(from));
    final updated = [
      for (var i = 0; i < list.length; i++) list[i].copyWith(sortOrder: i),
    ];
    state = updated;
    for (var i = 0; i < updated.length; i++) {
      final before = list[i].sortOrder;
      if (before != i) await _repo.save(updated[i]);
    }
  }

  /// Sets (or with null, clears) the summary shown above the changes.
  Future<void> setChangesSummary(
    String path,
    String? text, {
    bool byAi = false,
  }) => _modify(
    path,
    (r) => text == null || text.trim().isEmpty
        ? r.copyWith(clearChangesSummary: true, changesSummaryByAi: false)
        : r.copyWith(changesSummary: text.trim(), changesSummaryByAi: byAi),
  );

  Future<void> setAutoSummary(String path, bool on) =>
      _modify(path, (r) => r.copyWith(autoSummary: on));

  Future<void> markOpened(String path) =>
      _modify(path, (r) => r.copyWith(lastOpenedAt: DateTime.now()));

  Future<void> _modify(
    String path,
    TrackedRepo Function(TrackedRepo) edit,
  ) async {
    final current = state.where((r) => r.path == path).firstOrNull;
    if (current == null) return;
    final updated = edit(current);
    await _repo.save(updated);
    state = [for (final r in state) r.path == path ? updated : r];
  }

  /// Your own drag-and-drop order first; alphabetical until there is one
  /// (and among repos without a position).
  static List<TrackedRepo> _sorted(List<TrackedRepo> repos) => repos
    ..sort((a, b) {
      final byOrder = (a.sortOrder ?? _unordered).compareTo(
        b.sortOrder ?? _unordered,
      );
      if (byOrder != 0) return byOrder;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

  static const _unordered = 1 << 30;
}

final trackedReposProvider =
    NotifierProvider<TrackedReposController, List<TrackedRepo>>(
      TrackedReposController.new,
    );

/// Shared by the repository status checks, so "Refresh all" or coming back
/// to Gitty doesn't start dozens of git processes at the same moment.
final repoRefreshLimiter = TaskLimiter(4);

/// Live status of one repository. Invalidate to refresh.
final repoSnapshotProvider = FutureProvider.autoDispose
    .family<RepoSnapshot, String>((ref, path) async {
      // Keep the status for a while after its card scrolls out of view, so
      // scrolling back doesn't re-run git and flash the loading bar.
      ref.cacheFor(const Duration(minutes: 2));
      final analytics = ref.read(analyticsRepositoryProvider);
      final git = ref.watch(gitServiceProvider);
      final snapshot = await repoRefreshLimiter.run(() async {
        // Refreshed or no longer shown while waiting for a turn.
        if (!ref.mounted) throw const RefreshSkipped();
        // Folders added without Git get a friendly "Initialize Git" state.
        // (Missing folders fall through to the usual "doesn't exist" error.)
        if (Directory(path).existsSync() && !await git.isRepository(path)) {
          throw NotARepositoryException(path);
        }
        return git.snapshot(path);
      });
      // Light, throttled analytics: how often is the tree dirty when we look?
      unawaited(
        analytics.recordStatusCheck(path, dirty: !snapshot.status.isClean),
      );
      return snapshot;
    });

/// Keeps ahead/behind counts fresh by fetching in the background while the
/// app is open. Watched once by the home shell.
final autoFetchProvider = Provider<void>((ref) {
  final enabled = ref.watch(
    settingsControllerProvider.select((s) => s.autoFetch),
  );
  final minutes = ref.watch(
    settingsControllerProvider.select((s) => s.autoFetchMinutes),
  );
  // 0 means "None": no periodic background fetch.
  if (!enabled || minutes <= 0) return;

  var running = false;
  final timer = Timer.periodic(Duration(minutes: minutes.clamp(1, 240)), (
    _,
  ) async {
    if (running) return;
    running = true;
    try {
      // Fetches and turns teammates' pushes into notices (see live_sync).
      final updates = ref.read(remoteUpdatesProvider.notifier);
      for (final repo in ref.read(trackedReposProvider)) {
        if (!ref.mounted) return;
        await updates.check(repo.path);
      }
    } finally {
      running = false;
    }
  });
  ref.onDispose(timer.cancel);
});
