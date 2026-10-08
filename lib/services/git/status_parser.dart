import 'git_models.dart';

/// Parses the output of `git status --porcelain=v2 --branch -z`.
///
/// Format reference: https://git-scm.com/docs/git-status#_porcelain_format_version_2
///
/// With `-z`, every header/entry is NUL-terminated and paths are never quoted.
/// Rename entries (`2 ...`) are followed by an extra NUL-terminated record
/// containing the original path.
RepoStatus parsePorcelainV2(String output) {
  String? oid;
  String? branch;
  String? upstream;
  var ahead = 0;
  var behind = 0;
  final changes = <FileChange>[];

  final records = output.split('\u0000');
  for (var i = 0; i < records.length; i++) {
    final record = records[i];
    if (record.isEmpty) continue;

    if (record.startsWith('# ')) {
      final header = record.substring(2);
      if (header.startsWith('branch.oid ')) {
        final value = header.substring('branch.oid '.length);
        oid = value == '(initial)' ? null : value;
      } else if (header.startsWith('branch.head ')) {
        final value = header.substring('branch.head '.length);
        branch = value == '(detached)' ? null : value;
      } else if (header.startsWith('branch.upstream ')) {
        upstream = header.substring('branch.upstream '.length);
      } else if (header.startsWith('branch.ab ')) {
        // "+<ahead> -<behind>"
        final parts = header.substring('branch.ab '.length).split(' ');
        if (parts.length == 2) {
          ahead = int.tryParse(parts[0].replaceFirst('+', '')) ?? 0;
          behind = int.tryParse(parts[1].replaceFirst('-', '')) ?? 0;
        }
      }
      continue;
    }

    switch (record[0]) {
      case '1':
        // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
        final f = splitFields(record, 9);
        if (f.length < 9) continue;
        changes.add(_fromXY(f[1], f[8]));
      case '2':
        // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path> \0 <origPath>
        final f = splitFields(record, 10);
        if (f.length < 10) continue;
        final original = i + 1 < records.length ? records[++i] : null;
        changes.add(_fromXY(f[1], f[9], originalPath: original));
      case 'u':
        // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
        final f = splitFields(record, 11);
        if (f.length < 11) continue;
        changes.add(
          FileChange(
            path: f[10],
            kind: FileChangeKind.conflicted,
            staged: false,
            unstaged: true,
          ),
        );
      case '?':
        changes.add(
          FileChange(
            path: record.substring(2),
            kind: FileChangeKind.untracked,
            staged: false,
            unstaged: true,
          ),
        );
      default:
        // '!' (ignored) and anything unknown.
        break;
    }
  }

  return RepoStatus(
    branch: branch,
    upstream: upstream,
    ahead: ahead,
    behind: behind,
    changes: changes,
    headOid: oid,
  );
}

FileChange _fromXY(String xy, String path, {String? originalPath}) {
  final x = xy.isNotEmpty ? xy[0] : '.';
  final y = xy.length > 1 ? xy[1] : '.';
  return FileChange(
    path: path,
    originalPath: originalPath,
    kind: _kindFor(x != '.' ? x : y),
    staged: x != '.',
    unstaged: y != '.',
  );
}

FileChangeKind _kindFor(String code) => switch (code) {
  'A' => FileChangeKind.added,
  'D' => FileChangeKind.deleted,
  'R' => FileChangeKind.renamed,
  'C' => FileChangeKind.copied,
  'T' => FileChangeKind.typeChanged,
  'U' => FileChangeKind.conflicted,
  _ => FileChangeKind.modified,
};

/// Splits [line] on single spaces into at most [count] fields; the last field
/// keeps any remaining spaces (paths may contain spaces).
List<String> splitFields(String line, int count) {
  final result = <String>[];
  var start = 0;
  while (result.length < count - 1) {
    final space = line.indexOf(' ', start);
    if (space < 0) break;
    result.add(line.substring(start, space));
    start = space + 1;
  }
  result.add(line.substring(start));
  return result;
}
