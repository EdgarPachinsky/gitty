import 'package:path/path.dart' as p;

import '../ai/commit_style.dart';
import 'local_store.dart';

/// A repository the user added to Gitty.
class TrackedRepo {
  const TrackedRepo({
    required this.path,
    required this.addedAt,
    this.lastOpenedAt,
    this.preferredCommitStyle,
    this.displayName,
    this.pinned = false,
    this.sortOrder,
    this.changesSummary,
    this.changesSummaryByAi = false,
    this.autoSummary = false,
  });

  final String path;
  final DateTime addedAt;
  final DateTime? lastOpenedAt;

  /// Remembered per repository; null means "use the app default".
  final CommitStyle? preferredCommitStyle;

  /// The folder's name on disk.
  String get name => p.basename(path);

  /// Optional title shown in Gitty instead of the folder name. Purely
  /// cosmetic — the folder itself is never renamed.
  final String? displayName;

  /// Shown in the "Pinned" section at the top of the list.
  final bool pinned;

  /// Position chosen by dragging cards on the dashboard (lower = earlier).
  /// Null until the user reorders; then the list is sorted by title.
  final int? sortOrder;

  /// Short description of the uncommitted changes, shown above the list.
  /// Written by hand or by the AI; cleared once everything is committed.
  final String? changesSummary;

  /// [changesSummary] came from the AI (so it may be refreshed
  /// automatically; hand-written ones never are).
  final bool changesSummaryByAi;

  /// Refresh the AI summary automatically as the changes change.
  final bool autoSummary;

  /// What to show: the custom title, or the folder name.
  String get title =>
      displayName?.trim().isNotEmpty == true ? displayName!.trim() : name;

  TrackedRepo copyWith({
    DateTime? lastOpenedAt,
    CommitStyle? preferredCommitStyle,
    String? displayName,
    bool clearDisplayName = false,
    bool? pinned,
    int? sortOrder,
    String? changesSummary,
    bool clearChangesSummary = false,
    bool? changesSummaryByAi,
    bool? autoSummary,
  }) {
    return TrackedRepo(
      path: path,
      addedAt: addedAt,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      preferredCommitStyle: preferredCommitStyle ?? this.preferredCommitStyle,
      displayName: clearDisplayName ? null : displayName ?? this.displayName,
      pinned: pinned ?? this.pinned,
      sortOrder: sortOrder ?? this.sortOrder,
      changesSummary: clearChangesSummary
          ? null
          : changesSummary ?? this.changesSummary,
      changesSummaryByAi: changesSummaryByAi ?? this.changesSummaryByAi,
      autoSummary: autoSummary ?? this.autoSummary,
    );
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'addedAt': addedAt.toIso8601String(),
    'lastOpenedAt': lastOpenedAt?.toIso8601String(),
    'preferredCommitStyle': preferredCommitStyle?.name,
    'displayName': displayName,
    'pinned': pinned,
    'sortOrder': sortOrder,
    'changesSummary': changesSummary,
    'changesSummaryByAi': changesSummaryByAi,
    'autoSummary': autoSummary,
  };

  static TrackedRepo? fromJson(Map<String, dynamic> json) {
    final path = json['path'] as String?;
    if (path == null) return null;
    final style = json['preferredCommitStyle'] as String?;
    return TrackedRepo(
      path: path,
      addedAt:
          DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
      lastOpenedAt: DateTime.tryParse(json['lastOpenedAt'] as String? ?? ''),
      preferredCommitStyle: style == null ? null : CommitStyle.fromName(style),
      displayName: json['displayName'] as String?,
      pinned: json['pinned'] as bool? ?? false,
      sortOrder: (json['sortOrder'] as num?)?.toInt(),
      changesSummary: json['changesSummary'] as String?,
      changesSummaryByAi: json['changesSummaryByAi'] as bool? ?? false,
      autoSummary: json['autoSummary'] as bool? ?? false,
    );
  }
}

class RepoRepository {
  RepoRepository(this._store);

  final LocalStore _store;

  List<TrackedRepo> loadAll() {
    final repos = <TrackedRepo>[];
    for (final key in _store.repos.keys) {
      final json = LocalStore.readJson(_store.repos, key);
      final repo = json == null ? null : TrackedRepo.fromJson(json);
      if (repo != null) repos.add(repo);
    }
    return repos;
  }

  Future<void> save(TrackedRepo repo) => LocalStore.writeJson(
    _store.repos,
    LocalStore.keyFor(repo.path),
    repo.toJson(),
  );

  Future<void> remove(String path) =>
      _store.repos.delete(LocalStore.keyFor(path));
}
