import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Finds existing Git repositories on this machine.
///
/// Scans a handful of common "code" folders up to a limited depth, in a
/// background isolate so the UI stays smooth.
class RepoScanner {
  const RepoScanner();

  static const _maxResults = 300;
  static const _maxVisitedDirectories = 25000;

  /// Folder names we never descend into — large, irrelevant, or private.
  static const _skip = {
    'node_modules',
    'Library',
    'Applications',
    'AppData',
    'Pods',
    'build',
    'dist',
    'vendor',
    'target',
    'Pictures',
    'Music',
    'Movies',
    'Videos',
    'Photos Library.photoslibrary',
    r'$RECYCLE.BIN',
    'venv',
    '__pycache__',
  };

  static String? get homeDirectory =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  /// Common places people keep code.
  static List<String> defaultRoots() {
    final home = homeDirectory;
    if (home == null) return const [];
    final names = [
      'Developer',
      'Projects',
      'projects',
      'Code',
      'code',
      'dev',
      'Dev',
      'src',
      'repos',
      'Repos',
      'workspace',
      'Workspace',
      'git',
      'GitHub',
      'github',
      'Documents',
      'Desktop',
      'Sites',
      p.join('source', 'repos'),
    ];
    return [for (final n in names) p.join(home, n)];
  }

  /// Returns absolute paths of repositories found under [roots].
  Future<List<String>> scan({List<String>? roots, int maxDepth = 4}) {
    final effectiveRoots = roots ?? defaultRoots();
    return Isolate.run(() => _scanSync(effectiveRoots, maxDepth));
  }

  static List<String> _scanSync(List<String> roots, int maxDepth) {
    final found = <String>{};
    final seenDirs = <String>{};
    var visited = 0;

    for (final root in roots) {
      final rootDir = Directory(root);
      if (!rootDir.existsSync()) continue;

      final queue = <(Directory, int)>[(rootDir, 0)];
      while (queue.isNotEmpty) {
        if (found.length >= _maxResults || visited >= _maxVisitedDirectories) {
          return found.toList()..sort();
        }
        final (dir, depth) = queue.removeLast();

        // Resolve to avoid scanning the same folder twice (e.g. Desktop inside
        // Documents on some setups, or overlapping roots).
        String canonical;
        try {
          canonical = dir.resolveSymbolicLinksSync();
        } catch (_) {
          continue;
        }
        if (!seenDirs.add(canonical)) continue;
        visited++;

        final List<FileSystemEntity> children;
        try {
          children = dir.listSync(followLinks: false);
        } catch (_) {
          continue; // permission denied etc.
        }

        final isRepo = children.any((e) => p.basename(e.path) == '.git');
        if (isRepo) {
          found.add(p.normalize(dir.path));
          continue; // don't descend into repositories
        }
        if (depth >= maxDepth) continue;

        for (final child in children) {
          if (child is! Directory) continue;
          final name = p.basename(child.path);
          if (name.startsWith('.') || _skip.contains(name)) continue;
          queue.add((child, depth + 1));
        }
      }
    }
    return found.toList()..sort();
  }
}
