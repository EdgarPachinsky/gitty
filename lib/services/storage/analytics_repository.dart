import 'dart:convert';

import 'local_store.dart';

/// Things we count. Stored locally only — nothing ever leaves the machine.
enum AnalyticsEventType {
  commit,
  push,
  pull,
  fetch,
  statusCheck,
  branchCreated,
  branchSwitched,
  aiMessageGenerated,
}

class AnalyticsEvent {
  const AnalyticsEvent({
    required this.type,
    required this.repoPath,
    required this.at,
    this.meta = const {},
  });

  final AnalyticsEventType type;
  final String repoPath;
  final DateTime at;
  final Map<String, dynamic> meta;

  Map<String, dynamic> toJson() => {
    't': type.name,
    'r': repoPath,
    'at': at.millisecondsSinceEpoch,
    if (meta.isNotEmpty) 'm': meta,
  };

  static AnalyticsEvent? fromJson(Map<String, dynamic> json) {
    final typeName = json['t'] as String?;
    final repo = json['r'] as String?;
    final at = json['at'] as int?;
    if (typeName == null || repo == null || at == null) return null;
    final type = AnalyticsEventType.values
        .where((t) => t.name == typeName)
        .firstOrNull;
    if (type == null) return null;
    final meta = json['m'];
    return AnalyticsEvent(
      type: type,
      repoPath: repo,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      meta: meta is Map<String, dynamic> ? meta : const {},
    );
  }
}

/// Simple health metrics for one repository. Deliberately light for now —
/// the goal is to collect signal we can turn into better advice later.
class RepoInsights {
  const RepoInsights({
    required this.commitsLast7Days,
    required this.commitsLast30Days,
    required this.averageTimeBetweenCommits,
    required this.averagePullToPush,
    required this.dirtyShare,
    required this.lastPull,
    required this.lastPush,
  });

  final int commitsLast7Days;
  final int commitsLast30Days;
  final Duration? averageTimeBetweenCommits;

  /// Average time from a pull to the next push — a proxy for how long work
  /// stays unsynced.
  final Duration? averagePullToPush;

  /// Share (0..1) of status checks where the working tree had uncommitted
  /// changes; null if we have no data yet.
  final double? dirtyShare;
  final DateTime? lastPull;
  final DateTime? lastPush;

  bool get isEmpty =>
      commitsLast30Days == 0 &&
      lastPull == null &&
      lastPush == null &&
      dirtyShare == null;
}

class AnalyticsRepository {
  AnalyticsRepository(this._store);

  final LocalStore _store;

  static const _maxEvents = 5000;

  /// Throttle status checks per repo so auto-refresh doesn't skew the data.
  final Map<String, DateTime> _lastStatusCheck = {};
  static const _statusCheckInterval = Duration(minutes: 10);

  Future<void> record(AnalyticsEvent event) async {
    await _store.analytics.add(jsonEncode(event.toJson()));
    final overflow = _store.analytics.length - _maxEvents;
    if (overflow > 0) {
      await _store.analytics.deleteAll(
        _store.analytics.keys.take(overflow).toList(),
      );
    }
  }

  Future<void> recordStatusCheck(String repoPath, {required bool dirty}) async {
    final now = DateTime.now();
    final last = _lastStatusCheck[repoPath];
    if (last != null && now.difference(last) < _statusCheckInterval) return;
    _lastStatusCheck[repoPath] = now;
    await record(
      AnalyticsEvent(
        type: AnalyticsEventType.statusCheck,
        repoPath: repoPath,
        at: now,
        meta: {'dirty': dirty},
      ),
    );
  }

  List<AnalyticsEvent> eventsFor(String repoPath) {
    final events = <AnalyticsEvent>[];
    for (final raw in _store.analytics.values) {
      try {
        final json = jsonDecode(raw);
        if (json is! Map<String, dynamic>) continue;
        final e = AnalyticsEvent.fromJson(json);
        if (e != null && e.repoPath == repoPath) events.add(e);
      } catch (_) {
        // Skip corrupt entries.
      }
    }
    events.sort((a, b) => a.at.compareTo(b.at));
    return events;
  }

  RepoInsights insightsFor(String repoPath, {DateTime? now}) {
    final events = eventsFor(repoPath);
    final t = now ?? DateTime.now();

    final commits = events
        .where((e) => e.type == AnalyticsEventType.commit)
        .toList();
    final pulls = events
        .where((e) => e.type == AnalyticsEventType.pull)
        .toList();
    final pushes = events
        .where((e) => e.type == AnalyticsEventType.push)
        .toList();
    final checks = events
        .where((e) => e.type == AnalyticsEventType.statusCheck)
        .toList();

    Duration? avgBetweenCommits;
    if (commits.length >= 2) {
      final span = commits.last.at.difference(commits.first.at);
      avgBetweenCommits = Duration(
        microseconds: span.inMicroseconds ~/ (commits.length - 1),
      );
    }

    // For each push, find the latest pull before it.
    final pullToPush = <Duration>[];
    for (final push in pushes) {
      final before = pulls.where((p) => p.at.isBefore(push.at));
      if (before.isNotEmpty) pullToPush.add(push.at.difference(before.last.at));
    }
    Duration? avgPullToPush;
    if (pullToPush.isNotEmpty) {
      final total = pullToPush.fold<int>(0, (sum, d) => sum + d.inMicroseconds);
      avgPullToPush = Duration(microseconds: total ~/ pullToPush.length);
    }

    double? dirtyShare;
    if (checks.isNotEmpty) {
      final dirty = checks.where((c) => c.meta['dirty'] == true).length;
      dirtyShare = dirty / checks.length;
    }

    return RepoInsights(
      commitsLast7Days: commits
          .where((c) => t.difference(c.at).inDays < 7)
          .length,
      commitsLast30Days: commits
          .where((c) => t.difference(c.at).inDays < 30)
          .length,
      averageTimeBetweenCommits: avgBetweenCommits,
      averagePullToPush: avgPullToPush,
      dirtyShare: dirtyShare,
      lastPull: pulls.isEmpty ? null : pulls.last.at,
      lastPush: pushes.isEmpty ? null : pushes.last.at,
    );
  }
}
