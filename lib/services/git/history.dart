/// Friendly history for a repository:
/// - [ActivityEvent]s: what was *done* here (switched, committed, pulled,
///   pushed, created a branch…), read from Git's own diary — the reflog —
///   so it includes work done in a terminal or an editor, not just Gitty.
/// - [HistoryCommit]s: the commit log, including commits that are online
///   but not downloaded yet, and ones not uploaded yet.
library;

enum ActivityGroup { commits, branches, sync }

enum ActivityKind {
  commit(ActivityGroup.commits),
  firstCommit(ActivityGroup.commits),
  amend(ActivityGroup.commits),
  cherryPick(ActivityGroup.commits),
  revert(ActivityGroup.commits),
  switchBranch(ActivityGroup.branches),
  detach(ActivityGroup.branches),
  createBranch(ActivityGroup.branches),
  renameBranch(ActivityGroup.branches),
  merge(ActivityGroup.branches),
  rebase(ActivityGroup.branches),
  reset(ActivityGroup.branches),
  pull(ActivityGroup.sync),
  push(ActivityGroup.sync),
  publish(ActivityGroup.sync),
  fetch(ActivityGroup.sync),
  clone(ActivityGroup.sync),
  other(ActivityGroup.branches);

  const ActivityKind(this.group);
  final ActivityGroup group;
}

class ActivityEvent {
  const ActivityEvent({
    required this.kind,
    required this.time,
    required this.title,
    this.detail,
    this.hash,
    this.branch,
    this.oldHash,
    this.fromBranch,
    this.renamedFrom,
    this.remote,
  });

  final ActivityKind kind;
  final DateTime time;

  /// Plain sentence, e.g. "Switched from main to feature/login".
  final String title;

  /// Extra line, e.g. the commit message.
  final String? detail;

  /// Commit it resulted in, when there is one.
  final String? hash;

  /// Branch it happened on, when known.
  final String? branch;

  /// Where the branch pointed before this (for undo).
  final String? oldHash;

  /// For switches: the branch you came from.
  final String? fromBranch;

  /// For renames: the old name.
  final String? renamedFrom;

  /// For pushes: which remote (e.g. "origin").
  final String? remote;

  String? get shortHash =>
      hash == null ? null : (hash!.length > 7 ? hash!.substring(0, 7) : hash);
}

/// One commit in the Commits tab.
class HistoryCommit {
  const HistoryCommit({
    required this.hash,
    required this.parents,
    required this.author,
    required this.email,
    required this.date,
    required this.subject,
    required this.refs,
    this.onlineOnly = false,
    this.notPushed = false,
  });

  final String hash;
  final List<String> parents;
  final String author;
  final String email;
  final DateTime date;
  final String subject;

  /// Branch/tag labels pointing here, e.g. "main", "origin/main", "tag: v1".
  final List<String> refs;

  /// Online (on the linked branch) but not downloaded into yours yet.
  final bool onlineOnly;

  /// Yours, not uploaded yet.
  final bool notPushed;

  bool get isMerge => parents.length > 1;
  String get shortHash => hash.length > 7 ? hash.substring(0, 7) : hash;

  HistoryCommit copyWith({bool? onlineOnly, bool? notPushed}) => HistoryCommit(
    hash: hash,
    parents: parents,
    author: author,
    email: email,
    date: date,
    subject: subject,
    refs: refs,
    onlineOnly: onlineOnly ?? this.onlineOnly,
    notPushed: notPushed ?? this.notPushed,
  );
}

/// A file changed by a commit (from `git show --numstat`).
class CommitFileChange {
  const CommitFileChange({required this.path, this.added, this.deleted});

  final String path;

  /// Null for binary files.
  final int? added;
  final int? deleted;
}

class CommitDetails {
  const CommitDetails({required this.body, required this.files});

  /// Message body below the subject line (may be empty).
  final String body;
  final List<CommitFileChange> files;
}

// -----------------------------------------------------------------------------
// Parsing — pure functions, so they can run in a background isolate and be
// unit-tested.
// -----------------------------------------------------------------------------

/// `git log --format=` used for [parseCommitLog].
const commitLogFormat = '%H%x1f%P%x1f%an%x1f%ae%x1f%ct%x1f%D%x1f%s%x1e';

List<HistoryCommit> parseCommitLog(String output) {
  final commits = <HistoryCommit>[];
  for (final record in output.split('\u001e')) {
    final r = record.trim();
    if (r.isEmpty) continue;
    final f = r.split('\u001f');
    if (f.length < 7) continue;
    final seconds = int.tryParse(f[4]) ?? 0;
    commits.add(
      HistoryCommit(
        hash: f[0],
        parents: f[1].split(' ').where((s) => s.isNotEmpty).toList(),
        author: f[2],
        email: f[3],
        date: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
        refs: parseRefLabels(f[5]),
        subject: f.sublist(6).join('\u001f'),
      ),
    );
  }
  return commits;
}

/// "HEAD -> main, origin/main, origin/HEAD, tag: v1" → [main, origin/main,
/// tag: v1].
List<String> parseRefLabels(String decorations) => [
  for (final raw in decorations.split(', '))
    if (raw.trim().isNotEmpty &&
        raw.trim() != 'HEAD' &&
        !raw.trim().endsWith('/HEAD'))
      raw.trim().startsWith('HEAD -> ')
          ? raw.trim().substring('HEAD -> '.length)
          : raw.trim(),
];

/// Output of `git show --format=%b%x1e --numstat -M <hash>`.
CommitDetails parseCommitDetails(String output) {
  final split = output.indexOf('\u001e');
  final body = split < 0 ? '' : output.substring(0, split).trim();
  final stats = split < 0 ? output : output.substring(split + 1);
  final files = <CommitFileChange>[];
  for (final line in stats.split('\n')) {
    final parts = line.split('\t');
    if (parts.length < 3) continue;
    files.add(
      CommitFileChange(
        path: parts.sublist(2).join('\t'),
        added: int.tryParse(parts[0]),
        deleted: int.tryParse(parts[1]),
      ),
    );
  }
  return CommitDetails(body: body, files: files);
}

class _Entry {
  const _Entry(this.oldHash, this.newHash, this.time, this.message, this.order);

  final String oldHash;
  final String newHash;
  final DateTime time;
  final String message;

  /// Position in its file, to keep same-second events in order.
  final int order;
}

final _line = RegExp(r'^([0-9a-f]+) ([0-9a-f]+) .* (\d+) [+-]\d{4}$');
final _zeros = RegExp(r'^0+$');
final _hashLike = RegExp(r'^[0-9a-f]{7,64}$');

List<_Entry> _parseLog(List<String> lines) {
  final entries = <_Entry>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final tab = line.indexOf('\t');
    if (tab < 0) continue;
    final m = _line.firstMatch(line.substring(0, tab));
    if (m == null) continue;
    entries.add(
      _Entry(
        m.group(1)!,
        m.group(2)!,
        DateTime.fromMillisecondsSinceEpoch(int.parse(m.group(3)!) * 1000),
        line.substring(tab + 1).trim(),
        i,
      ),
    );
  }
  return entries;
}

String _short(String hash) => hash.length > 7 ? hash.substring(0, 7) : hash;

/// "refs/heads/main" → "main", "refs/remotes/origin/dev" → "origin/dev".
String _refName(String ref) => ref
    .replaceFirst(RegExp(r'^refs/heads/'), '')
    .replaceFirst(RegExp(r'^refs/remotes/'), '');

String _friendlyRef(String ref) =>
    _hashLike.hasMatch(ref) ? 'commit ${_short(ref)}' : _refName(ref);

String _capitalized(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Builds the activity timeline (newest first) from reflog files:
/// [headLog] = `.git/logs/HEAD`, [branchLogs] = `logs/refs/heads/<name>`,
/// [remoteLogs] = `logs/refs/remotes/<remote>/<name>` (keyed by
/// "<remote>/<name>"). [currentBranch] is where HEAD is now.
List<ActivityEvent> parseActivity({
  required List<String> headLog,
  Map<String, List<String>> branchLogs = const {},
  Map<String, List<String>> remoteLogs = const {},
  String? currentBranch,
  int limit = 400,
}) {
  final events = <(ActivityEvent, int)>[];
  var seq = 0;
  void add(ActivityEvent e) => events.add((e, seq++));

  // --- HEAD: commits, switches, pulls, merges, rebases, resets ------------
  final head = _parseLog(headLog);
  final checkout = RegExp(r'^checkout: moving from (.+) to (.+)$');

  // Which branch was checked out after each entry: walk backwards from now.
  final branchAfter = List<String?>.filled(head.length, null);
  var cur = currentBranch;
  for (var i = head.length - 1; i >= 0; i--) {
    branchAfter[i] = cur;
    final m = checkout.firstMatch(head[i].message);
    if (m != null) {
      final from = m.group(1)!;
      cur = _hashLike.hasMatch(from) ? null : from;
    }
  }

  String? rebaseOnto;
  String? rebaseStartOld; // branch tip before a rebase started
  String? pullStartOld; // … before a "pull --rebase" started
  for (var i = 0; i < head.length; i++) {
    final e = head[i];
    final msg = e.message;
    final on = branchAfter[i];
    final onText = on == null ? '' : ' on $on';
    final colon = msg.indexOf(': ');
    final cmd = colon < 0 ? msg : msg.substring(0, colon);
    final rest = colon < 0 ? '' : msg.substring(colon + 2);

    final co = checkout.firstMatch(msg);
    if (co != null) {
      final from = co.group(1)!;
      final to = co.group(2)!;
      if (from == to) continue;
      if (_hashLike.hasMatch(to)) {
        add(
          ActivityEvent(
            kind: ActivityKind.detach,
            time: e.time,
            title: 'Stepped onto an older commit (not on any branch)',
            detail: 'Commit ${_short(to)}',
            hash: e.newHash,
          ),
        );
      } else {
        add(
          ActivityEvent(
            kind: ActivityKind.switchBranch,
            time: e.time,
            title: _hashLike.hasMatch(from)
                ? 'Went back to $to'
                : 'Switched from $from to $to',
            branch: to,
            fromBranch: _hashLike.hasMatch(from) ? null : from,
            oldHash: e.oldHash,
          ),
        );
      }
      continue;
    }

    if (cmd == 'commit' || cmd.startsWith('commit (')) {
      final (kind, title) = switch (cmd) {
        'commit (initial)' => (ActivityKind.firstCommit, 'Made the first commit$onText'),
        'commit (amend)' => (ActivityKind.amend, 'Changed the last commit$onText'),
        'commit (merge)' => (ActivityKind.merge, 'Finished a merge$onText'),
        _ => (ActivityKind.commit, 'Committed$onText'),
      };
      add(
        ActivityEvent(
          kind: kind,
          time: e.time,
          title: title,
          detail: rest,
          hash: e.newHash,
          oldHash: e.oldHash,
          branch: on,
        ),
      );
      continue;
    }

    if (cmd.startsWith('pull')) {
      // Rebase steps inside a pull: only the finish counts.
      if (cmd.contains('(') && !cmd.contains('(finish)')) {
        if (cmd.contains('(start)')) pullStartOld = e.oldHash;
        continue;
      }
      final how = rest.toLowerCase().startsWith('fast-forward')
          ? 'Got the latest commits'
          : cmd.contains('(finish)')
          ? 'Got the latest commits and put yours on top'
          : rest.toLowerCase().contains('merge')
          ? 'Got the latest commits and joined them with a merge commit'
          : _capitalized(rest);
      add(
        ActivityEvent(
          kind: ActivityKind.pull,
          time: e.time,
          title: on == null ? 'Pulled' : 'Pulled into $on',
          detail: how,
          hash: e.newHash,
          oldHash: cmd.contains('(finish)')
              ? (pullStartOld ?? e.oldHash)
              : e.oldHash,
          branch: on,
        ),
      );
      continue;
    }

    if (cmd.startsWith('merge ')) {
      final what = _refName(cmd.substring('merge '.length));
      add(
        ActivityEvent(
          kind: ActivityKind.merge,
          time: e.time,
          title: on == null ? 'Merged $what' : 'Merged $what into $on',
          detail: rest.toLowerCase().startsWith('fast-forward')
              ? 'Simply moved forward — no merge commit needed'
              : 'Joined both histories with a merge commit',
          hash: e.newHash,
          oldHash: e.oldHash,
          branch: on,
        ),
      );
      continue;
    }

    if (cmd.startsWith('rebase')) {
      if (cmd.contains('(start)')) {
        rebaseStartOld = e.oldHash;
        rebaseOnto = rest.startsWith('checkout ')
            ? _friendlyRef(rest.substring('checkout '.length))
            : null;
        continue;
      }
      if (cmd.contains('(abort)')) {
        add(
          ActivityEvent(
            kind: ActivityKind.rebase,
            time: e.time,
            title: 'Cancelled a rebase',
            detail: 'Everything went back to how it was before',
            branch: on,
          ),
        );
        rebaseOnto = null;
        continue;
      }
      if (!cmd.contains('(finish)')) continue;
      final name = on ?? 'the branch';
      add(
        ActivityEvent(
          kind: ActivityKind.rebase,
          time: e.time,
          title: rebaseOnto == null
              ? 'Rebased $name'
              : 'Rebased $name onto $rebaseOnto',
          detail: 'Put your commits on top of the newer ones',
          hash: e.newHash,
          oldHash: rebaseStartOld,
          branch: on,
        ),
      );
      rebaseOnto = null;
      rebaseStartOld = null;
      continue;
    }

    if (cmd == 'reset') {
      final to = rest.replaceFirst('moving to ', '');
      if (to == 'HEAD') continue; // e.g. from stash — nothing moved
      add(
        ActivityEvent(
          kind: ActivityKind.reset,
          time: e.time,
          title: on == null ? 'Reset to ${_friendlyRef(to)}' : 'Reset $on to ${_friendlyRef(to)}',
          detail: 'Moved the branch to a different commit',
          hash: e.newHash,
          oldHash: e.oldHash,
          branch: on,
        ),
      );
      continue;
    }

    if (cmd == 'cherry-pick' || cmd == 'revert') {
      final picked = cmd == 'cherry-pick';
      add(
        ActivityEvent(
          kind: picked ? ActivityKind.cherryPick : ActivityKind.revert,
          time: e.time,
          title: picked
              ? 'Copied a commit$onText'
              : 'Undid a commit$onText',
          detail: rest,
          hash: e.newHash,
          oldHash: e.oldHash,
          branch: on,
        ),
      );
      continue;
    }

    if (cmd == 'clone') {
      add(
        ActivityEvent(
          kind: ActivityKind.clone,
          time: e.time,
          title: 'Downloaded this repository (clone)',
          detail: rest.replaceFirst('from ', 'From '),
          hash: e.newHash,
        ),
      );
      continue;
    }

    // Anything else Git noted.
    add(
      ActivityEvent(
        kind: ActivityKind.other,
        time: e.time,
        title: _capitalized(msg),
        hash: e.newHash,
        branch: on,
      ),
    );
  }

  // Branch the user was on at [time] (for "Created from HEAD").
  String? branchAt(DateTime time) {
    String? found;
    for (var i = 0; i < head.length; i++) {
      if (head[i].time.isAfter(time)) break;
      final m = checkout.firstMatch(head[i].message);
      // Created right before switching to it: the branch it came from.
      if (m != null && !head[i].time.isBefore(time)) return m.group(1);
      found = branchAfter[i];
    }
    return found;
  }

  // --- Branches: created / renamed / moved ---------------------------------
  final created = RegExp(r'^branch: created from (.+)$', caseSensitive: false);
  final renamed = RegExp(
    r'^branch: renamed (\S+) to (\S+)$',
    caseSensitive: false,
  );
  final moved = RegExp(r'^branch: reset to (.+)$', caseSensitive: false);
  branchLogs.forEach((name, lines) {
    for (final e in _parseLog(lines)) {
      final c = created.firstMatch(e.message);
      if (c != null) {
        final raw = c.group(1)!;
        final from = raw == 'HEAD' ? branchAt(e.time) : _friendlyRef(raw);
        add(
          ActivityEvent(
            kind: ActivityKind.createBranch,
            time: e.time,
            title: from == null || from == name
                ? 'Created branch $name'
                : 'Created branch $name from $from',
            hash: e.newHash,
            branch: name,
          ),
        );
        continue;
      }
      final r = renamed.firstMatch(e.message);
      if (r != null) {
        add(
          ActivityEvent(
            kind: ActivityKind.renameBranch,
            time: e.time,
            title:
                'Renamed branch ${_refName(r.group(1)!)} to ${_refName(r.group(2)!)}',
            branch: _refName(r.group(2)!),
            renamedFrom: _refName(r.group(1)!),
          ),
        );
        continue;
      }
      final mv = moved.firstMatch(e.message);
      if (mv != null) {
        add(
          ActivityEvent(
            kind: ActivityKind.reset,
            time: e.time,
            title: 'Moved branch $name to ${_friendlyRef(mv.group(1)!)}',
            hash: e.newHash,
            branch: name,
          ),
        );
      }
    }
  });

  // --- Remote copies: pushes and downloads ---------------------------------
  // Downloads update several branches at once: one event per download.
  final downloads = <String, _Download>{};
  remoteLogs.forEach((key, lines) {
    final slash = key.indexOf('/');
    if (slash < 0) return;
    final remote = key.substring(0, slash);
    final name = key.substring(slash + 1);
    if (name == 'HEAD') return;
    for (final e in _parseLog(lines)) {
      final msg = e.message.toLowerCase();
      if (msg.startsWith('update by push')) {
        final isNew = _zeros.hasMatch(e.oldHash);
        add(
          ActivityEvent(
            kind: isNew ? ActivityKind.publish : ActivityKind.push,
            time: e.time,
            title: isNew
                ? 'Published $name to $remote'
                : 'Pushed $name to $remote',
            detail: isNew
                ? 'The branch is now online too'
                : 'Uploaded your new commits',
            hash: e.newHash,
            oldHash: e.oldHash,
            branch: name,
            remote: remote,
          ),
        );
        continue;
      }
      if (msg.startsWith('fetch') || msg.startsWith('pull')) {
        // Same download = same remote within a few seconds.
        final bucket = '$remote@${e.time.millisecondsSinceEpoch ~/ 5000}';
        final d = downloads.putIfAbsent(
          bucket,
          () => _Download(remote, e.time),
        );
        if (msg.endsWith('forced-update')) {
          d.rewritten.add(name);
        } else if (msg.endsWith('storing head') || _zeros.hasMatch(e.oldHash)) {
          d.added.add(name);
        } else {
          d.updated.add(name);
        }
      }
    }
  });
  for (final d in downloads.values) {
    String names(List<String> l) => l.length <= 3
        ? l.join(', ')
        : '${l.take(3).join(', ')} and ${l.length - 3} more';
    final parts = [
      if (d.updated.isNotEmpty)
        '${names(d.updated)} got new commits',
      if (d.added.isNotEmpty)
        d.added.length == 1
            ? 'new branch ${d.added.first}'
            : 'new branches ${names(d.added)}',
      if (d.rewritten.isNotEmpty)
        '${names(d.rewritten)} ${d.rewritten.length == 1 ? 'was' : 'were'} rewritten online',
    ];
    add(
      ActivityEvent(
        kind: ActivityKind.fetch,
        time: d.time,
        title: 'Downloaded news from ${d.remote}',
        detail: _capitalized(parts.join(' · ')),
      ),
    );
  }

  // --- Tidy up --------------------------------------------------------------
  // "Created branch x" + "Switched to x" at the same moment → one event.
  final list = events.toList();
  final drop = <int>{};
  for (var i = 0; i < list.length; i++) {
    final (c, _) = list[i];
    if (c.kind != ActivityKind.createBranch) continue;
    for (var j = 0; j < list.length; j++) {
      final (s, _) = list[j];
      if (s.kind == ActivityKind.switchBranch &&
          s.branch == c.branch &&
          s.time.difference(c.time).inSeconds.abs() <= 2) {
        drop.add(j);
        list[i] = (
          ActivityEvent(
            kind: c.kind,
            time: c.time,
            title: '${c.title} and switched to it',
            hash: c.hash,
            branch: c.branch,
            fromBranch: s.fromBranch,
          ),
          list[i].$2,
        );
        break;
      }
    }
  }
  final result = [
    for (var i = 0; i < list.length; i++)
      if (!drop.contains(i)) list[i],
  ]..sort((a, b) {
      final t = b.$1.time.compareTo(a.$1.time);
      return t != 0 ? t : b.$2.compareTo(a.$2);
    });
  return [for (final (e, _) in result.take(limit)) e];
}

class _Download {
  _Download(this.remote, this.time);

  final String remote;
  final DateTime time;
  final updated = <String>[];
  final added = <String>[];
  final rewritten = <String>[];
}
