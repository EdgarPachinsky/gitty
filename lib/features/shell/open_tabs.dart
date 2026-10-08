import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/service_providers.dart';
import '../../services/storage/local_store.dart';

/// Repositories open as tabs, and which one is showing (null = the
/// repositories list). Remembered between launches.
class OpenTabs {
  const OpenTabs({this.paths = const [], this.active});

  final List<String> paths;
  final String? active;
}

class OpenTabsController extends Notifier<OpenTabs> {
  static const _key = 'open_tabs';

  LocalStore get _store => ref.read(localStoreProvider);

  @override
  OpenTabs build() {
    final json = LocalStore.readJson(ref.watch(localStoreProvider).settings, _key);
    if (json == null) return const OpenTabs();
    final paths = [
      for (final p in (json['paths'] as List? ?? const []))
        if (p is String) p,
    ];
    final active = json['active'] as String?;
    return OpenTabs(
      paths: paths,
      active: paths.contains(active) ? active : null,
    );
  }

  void _set(List<String> paths, String? active) {
    state = OpenTabs(paths: List.unmodifiable(paths), active: active);
    unawaited(
      LocalStore.writeJson(_store.settings, _key, {
        'paths': paths,
        'active': active,
      }),
    );
  }

  /// Opens [path] in a tab (next to the current one) and shows it.
  void open(String path) {
    final paths = [...state.paths];
    if (!paths.contains(path)) {
      final at = state.active == null ? -1 : paths.indexOf(state.active!);
      paths.insert(at < 0 ? paths.length : at + 1, path);
    }
    _set(paths, path);
  }

  /// Shows [path]'s tab, or the repositories list for null.
  void activate(String? path) {
    if (path != null && !state.paths.contains(path)) return;
    if (path == state.active) return;
    _set(state.paths, path);
  }

  void close(String path) {
    final paths = [...state.paths];
    final i = paths.indexOf(path);
    if (i < 0) return;
    paths.removeAt(i);
    var active = state.active;
    if (active == path) {
      // Like a browser: the tab to the right, else the one to the left.
      active = paths.isEmpty ? null : paths[i < paths.length ? i : i - 1];
    }
    _set(paths, active);
  }

  void closeOthers(String path) {
    if (!state.paths.contains(path)) return;
    _set([path], path);
  }

  void closeAll() => _set(const [], null);

  /// Moves a tab (drag and drop on the tab strip).
  void move(String path, int toIndex) {
    final paths = [...state.paths];
    final from = paths.indexOf(path);
    if (from < 0) return;
    paths.removeAt(from);
    paths.insert(toIndex.clamp(0, paths.length), path);
    _set(paths, state.active);
  }

  /// Next / previous tab (the repositories list counts as the first one).
  void cycle(int delta) {
    final all = <String?>[null, ...state.paths];
    final i = all.indexOf(state.active);
    final next = all[(i + delta) % all.length];
    _set(state.paths, next);
  }

  /// Forgets tabs of repositories that were removed from Gitty.
  void retainOnly(Set<String> tracked) {
    final paths = state.paths.where(tracked.contains).toList();
    final active = tracked.contains(state.active) ? state.active : null;
    if (paths.length == state.paths.length && active == state.active) return;
    _set(paths, active);
  }
}

final openTabsProvider = NotifierProvider<OpenTabsController, OpenTabs>(
  OpenTabsController.new,
);
