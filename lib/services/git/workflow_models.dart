/// Models for "put changes aside" (stash), conflicts and undo.
library;

// --- Changes put aside (stash) -------------------------------------------------

class StashEntry {
  const StashEntry({
    required this.hash,
    required this.index,
    required this.message,
    required this.date,
    this.branch,
    this.named = true,
  });

  final String hash;

  /// Position in `git stash list` (0 = newest).
  final int index;

  /// The name given when it was put aside.
  final String message;
  final DateTime date;

  /// Branch it was put aside from.
  final String? branch;

  /// False for Git's automatic "WIP on main: …" names.
  final bool named;

  /// Made by Gitty right before reverting files (so revert can be undone).
  bool get isGittyBackup => message.startsWith('Gitty backup');
}

/// A file in a stash or commit, from `--name-status`.
class NameStatus {
  const NameStatus({required this.status, required this.path});

  /// A, M, D, R, C…
  final String status;
  final String path;

  String get friendly => switch (status.isEmpty ? '' : status[0]) {
    'A' => 'new',
    'D' => 'deleted',
    'R' => 'renamed',
    'C' => 'copied',
    _ => 'changed',
  };
}

final _stashSubject = RegExp(r'^(WIP )?[Oo]n ([^:]+): (.*)$');

/// `git stash list --format=%H%x1f%ct%x1f%gs`
List<StashEntry> parseStashList(String output) {
  final entries = <StashEntry>[];
  var index = 0;
  for (final line in output.split('\n')) {
    final f = line.split('\u001f');
    if (f.length < 3) continue;
    final m = _stashSubject.firstMatch(f[2]);
    final wip = m?.group(1) != null;
    entries.add(
      StashEntry(
        hash: f[0],
        index: index++,
        date: DateTime.fromMillisecondsSinceEpoch(
          (int.tryParse(f[1]) ?? 0) * 1000,
        ),
        branch: m?.group(2),
        message: m == null
            ? f[2]
            : wip
            ? 'Changes put aside (no name)'
            : m.group(3)!,
        named: m != null && !wip,
      ),
    );
  }
  return entries;
}

/// `--name-status` output ("M\tpath", "R100\told\tnew").
List<NameStatus> parseNameStatus(String output) => [
  for (final line in output.split('\n'))
    if (line.contains('\t'))
      NameStatus(
        status: line.split('\t').first.trim(),
        path: line.split('\t').last.trim(),
      ),
];

// --- Conflicts -------------------------------------------------------------------

/// What was going on when the clash happened.
enum ConflictOperation { merge, rebase, cherryPick, revert, other }

class ConflictState {
  const ConflictState({
    required this.operation,
    required this.files,
    this.incoming,
    this.currentBranch,
  });

  final ConflictOperation operation;

  /// Files that still have clashes.
  final List<ConflictFile> files;

  /// What's coming in (branch/commit name), when known.
  final String? incoming;
  final String? currentBranch;

  /// Plain sentence, e.g. "Merging dev into main".
  String get description {
    final into = currentBranch == null ? '' : ' into $currentBranch';
    final what = incoming == null ? '' : ' $incoming';
    return switch (operation) {
      ConflictOperation.merge => 'Merging$what$into',
      ConflictOperation.rebase =>
        'Rebasing${currentBranch == null ? '' : ' $currentBranch'}'
            '${incoming == null ? '' : ' onto $incoming'}',
      ConflictOperation.cherryPick => 'Copying a commit$into',
      ConflictOperation.revert => 'Undoing a commit$into',
      ConflictOperation.other => 'Bringing changes back',
    };
  }

  /// Friendly names for the two sides of a clash. Git calls them "ours"
  /// (HEAD) and "theirs" — which is backwards during a rebase.
  (String ours, String theirs) get sideNames => switch (operation) {
    ConflictOperation.merge => (
      'Yours${currentBranch == null ? '' : ' ($currentBranch)'}',
      'Incoming${incoming == null ? '' : ' ($incoming)'}',
    ),
    ConflictOperation.rebase => (
      'Newer version${incoming == null ? '' : ' ($incoming)'}',
      'Your commit',
    ),
    ConflictOperation.cherryPick => ('Yours', 'The copied commit'),
    ConflictOperation.revert => ('Yours', 'The undo'),
    ConflictOperation.other => ('Current files', 'Changes brought back'),
  };

  /// Button label to finish, or null when nothing is left to finish.
  String? get finishLabel => switch (operation) {
    ConflictOperation.merge => 'Finish merge',
    ConflictOperation.rebase => 'Continue rebase',
    ConflictOperation.cherryPick => 'Finish copying',
    ConflictOperation.revert => 'Finish undo',
    ConflictOperation.other => null,
  };

  String? get cancelLabel => switch (operation) {
    ConflictOperation.merge => 'Cancel merge',
    ConflictOperation.rebase => 'Cancel rebase',
    ConflictOperation.cherryPick => 'Cancel copying',
    ConflictOperation.revert => 'Cancel undo',
    ConflictOperation.other => null,
  };
}

class ConflictFile {
  const ConflictFile({
    required this.path,
    required this.inOurs,
    required this.inTheirs,
  });

  final String path;

  /// The file exists on that side (false = that side deleted it).
  final bool inOurs;
  final bool inTheirs;

  bool get isDeleteConflict => !inOurs || !inTheirs;
}

/// `git ls-files -u` ("mode sha stage\tpath"): stage 2 = ours, 3 = theirs.
List<ConflictFile> parseUnmerged(String output) {
  final stages = <String, Set<int>>{};
  for (final line in output.split('\n')) {
    final tab = line.indexOf('\t');
    if (tab < 0) continue;
    final meta = line.substring(0, tab).split(' ');
    if (meta.length < 3) continue;
    final stage = int.tryParse(meta[2]) ?? 0;
    stages.putIfAbsent(line.substring(tab + 1), () => {}).add(stage);
  }
  return [
    for (final e in stages.entries)
      ConflictFile(
        path: e.key,
        inOurs: e.value.contains(2),
        inTheirs: e.value.contains(3),
      ),
  ]..sort((a, b) => a.path.compareTo(b.path));
}

/// A piece of a conflicted file: plain text, or a clash between two sides.
sealed class ConflictSegment {
  const ConflictSegment();
}

class PlainSegment extends ConflictSegment {
  const PlainSegment(this.text);

  final String text;
}

class ClashSegment extends ConflictSegment {
  const ClashSegment({
    required this.ours,
    required this.theirs,
    this.base,
    this.oursLabel,
    this.theirsLabel,
  });

  final String ours;
  final String theirs;

  /// The version both started from (only with `merge.conflictStyle=diff3`).
  final String? base;
  final String? oursLabel;
  final String? theirsLabel;
}

/// Splits a file with `<<<<<<<` / `=======` / `>>>>>>>` markers into
/// segments. Line endings are kept exactly; joining every segment's text
/// back (with a side picked for each clash) rebuilds the file.
List<ConflictSegment> parseConflictMarkers(String text) {
  final lines = text.split('\n');
  final segments = <ConflictSegment>[];
  final plain = StringBuffer();
  var i = 0;

  // Lines are re-joined with '\n'; the last line has none after it.
  String joinLines(List<String> ls, {required bool endsFile}) {
    if (ls.isEmpty) return '';
    return endsFile ? ls.join('\n') : '${ls.join('\n')}\n';
  }

  bool marker(String line, String m) =>
      line.startsWith(m) &&
      (line.length == 7 || line[7] == ' ' || line[7] == '\r');

  while (i < lines.length) {
    final line = lines[i];
    if (!marker(line, '<<<<<<<')) {
      plain.write(line);
      if (i < lines.length - 1) plain.write('\n');
      i++;
      continue;
    }
    // Find the end of this clash; give up (treat as text) if it's broken.
    var j = i + 1;
    int? baseAt;
    int? splitAt;
    int? endAt;
    for (; j < lines.length; j++) {
      if (splitAt == null && baseAt == null && marker(lines[j], '|||||||')) {
        baseAt = j;
      } else if (splitAt == null && marker(lines[j], '=======')) {
        splitAt = j;
      } else if (splitAt != null && marker(lines[j], '>>>>>>>')) {
        endAt = j;
        break;
      }
    }
    if (splitAt == null || endAt == null) {
      plain.write(line);
      if (i < lines.length - 1) plain.write('\n');
      i++;
      continue;
    }
    if (plain.isNotEmpty) {
      segments.add(PlainSegment(plain.toString()));
      plain.clear();
    }
    final oursEnd = baseAt ?? splitAt;
    final endsFile = endAt == lines.length - 1;
    String label(String l) => l.length > 8 ? l.substring(8).trim() : '';
    segments.add(
      ClashSegment(
        ours: joinLines(lines.sublist(i + 1, oursEnd), endsFile: false),
        base: baseAt == null
            ? null
            : joinLines(lines.sublist(baseAt + 1, splitAt), endsFile: false),
        theirs: joinLines(lines.sublist(splitAt + 1, endAt), endsFile: false),
        oursLabel: label(line),
        theirsLabel: label(lines[endAt]),
      ),
    );
    i = endAt + 1;
    // The marker line's own newline belongs to the clash; if the file ended
    // right after it, there's nothing more to add.
    if (endsFile) break;
  }
  if (plain.isNotEmpty) segments.add(PlainSegment(plain.toString()));
  return segments;
}

// --- Branch list (Switch branch) -------------------------------------------------

class BranchSummary {
  const BranchSummary({
    required this.name,
    required this.remoteOnly,
    required this.lastCommit,
    this.upstream,
    this.subject = '',
  });

  final String name;

  /// Exists online only (switching to it makes a local copy).
  final bool remoteOnly;
  final DateTime lastCommit;

  /// e.g. "origin/feature/x" when the local branch is linked online.
  final String? upstream;

  /// Message of its latest commit.
  final String subject;
}

/// `git for-each-ref --sort=-committerdate
///   --format=%(refname)%09%(committerdate:unix)%09%(upstream:short)%09%(contents:subject)
///   refs/heads refs/remotes`
List<BranchSummary> parseBranchSummaries(String output) {
  final local = <BranchSummary>[];
  final remote = <String, BranchSummary>{};
  for (final line in output.split('\n')) {
    final f = line.split('\t');
    if (f.length < 2) continue;
    final ref = f[0];
    final date = DateTime.fromMillisecondsSinceEpoch(
      (int.tryParse(f[1]) ?? 0) * 1000,
    );
    final upstream = f.length > 2 && f[2].isNotEmpty ? f[2] : null;
    final subject = f.length > 3 ? f.sublist(3).join('\t') : '';
    if (ref.startsWith('refs/heads/')) {
      local.add(
        BranchSummary(
          name: ref.substring('refs/heads/'.length),
          remoteOnly: false,
          lastCommit: date,
          upstream: upstream,
          subject: subject,
        ),
      );
    } else if (ref.startsWith('refs/remotes/')) {
      final rest = ref.substring('refs/remotes/'.length);
      final slash = rest.indexOf('/');
      if (slash < 0) continue;
      final name = rest.substring(slash + 1);
      if (name == 'HEAD') continue;
      remote.putIfAbsent(
        name,
        () => BranchSummary(
          name: name,
          remoteOnly: true,
          lastCommit: date,
          subject: subject,
        ),
      );
    }
  }
  final localNames = {for (final b in local) b.name};
  return [
    ...local,
    for (final b in remote.values)
      if (!localNames.contains(b.name)) b,
  ];
}
