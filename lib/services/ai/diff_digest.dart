/// Turns a raw `git diff` into a short digest that small local models can
/// actually follow: every file with its +/− counts and the functions or
/// sections that changed, then only the changed lines that carry meaning
/// (no blank lines, lone brackets or import shuffles). Room is shared by
/// how much each file changed, with a little for every file, so one huge
/// file can't push the others out.
library;

import 'dart:math';

class _FileDigest {
  _FileDigest(this.path);

  String path;
  String? note; // new file / deleted / renamed / binary
  int added = 0;
  int removed = 0;
  bool importsChanged = false;
  final contexts = <String>{};
  final lines = <String>[];

  int get size => added + removed;
}

final _fileHeader = RegExp(r'^diff --git a/(.*) b/(.*)$');
final _hunk = RegExp(r'^@@ [^@]* @@ ?(.*)$');
final _onlyPunctuation = RegExp(r'^[\s{}()\[\];,.<>/*\-=+|&!?:]*$');
final _importLike = RegExp(
  r'^(import\s|export\s.*\sfrom\s|from\s+\S+\s+import\s|#include\s|using\s|'
  r'use\s|require\(|const\s+\w+\s*=\s*require\(|package\s)',
);

String digestDiff(String diff, {int maxChars = 4500}) {
  final files = <_FileDigest>[];
  _FileDigest? f;
  for (final raw in diff.split('\n')) {
    final header = _fileHeader.firstMatch(raw);
    if (header != null) {
      f = _FileDigest(header.group(2)!);
      files.add(f);
      continue;
    }
    final file = f;
    if (file == null) continue;
    if (raw.startsWith('new file')) {
      file.note = 'new file';
    } else if (raw.startsWith('deleted file')) {
      file.note = 'deleted';
    } else if (raw.startsWith('rename from ')) {
      file.note = 'renamed from ${raw.substring('rename from '.length)}';
    } else if (raw.startsWith('Binary files')) {
      file.note = 'binary';
    } else if (raw.startsWith('+++') || raw.startsWith('---')) {
      continue;
    } else if (raw.startsWith('@@')) {
      final context = _hunk.firstMatch(raw)?.group(1)?.trim() ?? '';
      if (context.isNotEmpty) {
        file.contexts.add(
          context.length > 70 ? '${context.substring(0, 70)}…' : context,
        );
      }
    } else if (raw.startsWith('+') || raw.startsWith('-')) {
      final added = raw.startsWith('+');
      if (added) {
        file.added++;
      } else {
        file.removed++;
      }
      final text = raw.substring(1).trim();
      if (text.isEmpty || _onlyPunctuation.hasMatch(text)) continue;
      if (_importLike.hasMatch(text)) {
        file.importsChanged = true;
        continue;
      }
      final shown = text.length > 140 ? '${text.substring(0, 140)}…' : text;
      file.lines.add('${added ? '+' : '-'} $shown');
    }
  }
  if (files.isEmpty) {
    return diff.length > maxChars ? diff.substring(0, maxChars) : diff;
  }

  // Headers first (always), then lines in the room that's left — shared out
  // by how much each file changed, but at least a little for every file.
  String head(_FileDigest d) {
    final b = StringBuffer('${d.path} (+${d.added} −${d.removed})');
    if (d.note != null) b.write(' [${d.note}]');
    if (d.contexts.isNotEmpty) {
      b.write('\n  in: ${d.contexts.take(4).join(', ')}');
    }
    if (d.importsChanged) b.write('\n  (imports changed)');
    return b.toString();
  }

  final heads = [for (final d in files) head(d)];
  final headChars = heads.fold<int>(0, (n, h) => n + h.length + 1);
  var room = maxChars - headChars;
  final total = max(1, files.fold<int>(0, (n, d) => n + d.size));

  final out = StringBuffer();
  for (var i = 0; i < files.length; i++) {
    final d = files[i];
    out.writeln(heads[i]);
    if (room <= 0 || d.lines.isEmpty) continue;
    final share = min(room, max(160, (room * d.size / total).floor()));
    var used = 0;
    var shownLines = 0;
    for (final line in d.lines) {
      if (used + line.length + 3 > share) break;
      out.writeln('  $line');
      used += line.length + 3;
      shownLines++;
    }
    if (shownLines < d.lines.length) {
      out.writeln('  … ${d.lines.length - shownLines} more changed lines');
    }
    room -= used;
  }
  return out.toString().trimRight();
}
