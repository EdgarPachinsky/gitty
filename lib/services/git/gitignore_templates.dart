/// Built-in .gitignore templates, written for humans: every group of rules
/// comes with a plain-language reason, so Gitty can show *what* will be
/// ignored and *why* before anything is written. Works offline.
library;

enum GitignoreCategory {
  project('For your project'),
  system('Operating systems'),
  habits('Good habits');

  const GitignoreCategory(this.label);
  final String label;
}

/// A group of patterns with one reason, e.g. "Dependencies — node_modules/".
class GitignoreSection {
  const GitignoreSection(this.title, this.why, this.patterns);

  final String title;
  final String why;
  final List<String> patterns;
}

class GitignoreTemplate {
  const GitignoreTemplate({
    required this.id,
    required this.label,
    required this.summary,
    required this.category,
    required this.sections,
    this.markers = const [],
    this.markerExtensions = const [],
  });

  final String id;
  final String label;

  /// One friendly sentence shown on the chip's tooltip / preview header.
  final String summary;
  final GitignoreCategory category;
  final List<GitignoreSection> sections;

  /// Top-level file or folder names that suggest this template.
  final List<String> markers;

  /// Top-level file extensions that suggest this template (e.g. `.py`).
  final List<String> markerExtensions;

  Iterable<String> get patterns => sections.expand((s) => s.patterns);
}

const gitignoreTemplates = <GitignoreTemplate>[
  // --- Projects -------------------------------------------------------------
  GitignoreTemplate(
    id: 'flutter',
    label: 'Flutter / Dart',
    summary: 'Build output and tool caches that Flutter recreates on its own.',
    category: GitignoreCategory.project,
    markers: ['pubspec.yaml'],
    sections: [
      GitignoreSection(
        'Build output',
        'Compiled app files — rebuilt every time you run the app.',
        ['build/', '**/Flutter/ephemeral/', '**/Generated.xcconfig'],
      ),
      GitignoreSection(
        'Tool caches',
        'Dart and Flutter keep their working files here.',
        [
          '.dart_tool/',
          '.packages',
          '.pub-cache/',
          '.pub/',
          '.flutter-plugins',
          '.flutter-plugins-dependencies',
        ],
      ),
      GitignoreSection(
        'Native dependencies',
        'Downloaded by CocoaPods and Gradle when you build.',
        [
          '**/Pods/',
          '.gradle/',
          'android/local.properties',
          'android/key.properties',
        ],
      ),
      GitignoreSection(
        'Test coverage',
        'Reports from `flutter test --coverage`.',
        ['coverage/'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'node',
    label: 'Node / JavaScript',
    summary: 'Installed packages and build folders — `npm install` brings them back.',
    category: GitignoreCategory.project,
    markers: ['package.json'],
    sections: [
      GitignoreSection(
        'Dependencies',
        'Installed packages — often thousands of files.',
        ['node_modules/', '.pnpm-store/', '.yarn/cache/'],
      ),
      GitignoreSection(
        'Build output',
        'Bundles made by your build tool.',
        ['dist/', 'build/', '.next/', '.nuxt/', 'out/'],
      ),
      GitignoreSection(
        'Caches',
        'Speed-up files from bundlers and test runners.',
        ['.cache/', '.parcel-cache/', '.turbo/', '.eslintcache', 'coverage/'],
      ),
      GitignoreSection(
        'Package-manager logs',
        'Crash logs from npm, yarn and pnpm.',
        ['npm-debug.log*', 'yarn-debug.log*', 'yarn-error.log*', 'pnpm-debug.log*'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'python',
    label: 'Python',
    summary: 'Bytecode, virtual environments and tool caches.',
    category: GitignoreCategory.project,
    markers: ['requirements.txt', 'pyproject.toml', 'setup.py', 'Pipfile'],
    markerExtensions: ['.py', '.ipynb'],
    sections: [
      GitignoreSection(
        'Compiled bytecode',
        'Python writes these automatically when it runs your code.',
        ['__pycache__/', '*.py[cod]'],
      ),
      GitignoreSection(
        'Virtual environments',
        'Your locally installed packages — recreate with pip.',
        ['.venv/', 'venv/', 'env/'],
      ),
      GitignoreSection(
        'Packaging',
        'Built wheels and eggs.',
        ['dist/', 'build/', '*.egg-info/'],
      ),
      GitignoreSection(
        'Tool caches',
        'pytest, mypy, ruff and Jupyter scratch files.',
        [
          '.pytest_cache/',
          '.mypy_cache/',
          '.ruff_cache/',
          '.ipynb_checkpoints/',
          '.coverage',
        ],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'java',
    label: 'Java / Kotlin',
    summary: 'Gradle and Maven build folders and compiled classes.',
    category: GitignoreCategory.project,
    markers: [
      'build.gradle',
      'build.gradle.kts',
      'settings.gradle',
      'settings.gradle.kts',
      'pom.xml',
    ],
    sections: [
      GitignoreSection(
        'Build output',
        'Compiled classes and packages.',
        ['build/', 'target/', 'out/', '*.class'],
      ),
      GitignoreSection(
        'Gradle caches',
        'Gradle’s local working files.',
        ['.gradle/', 'local.properties'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'swift',
    label: 'Swift / Xcode',
    summary: 'Xcode user state and build products.',
    category: GitignoreCategory.project,
    markers: ['Package.swift', 'Podfile'],
    markerExtensions: ['.xcodeproj', '.xcworkspace'],
    sections: [
      GitignoreSection(
        'Build products',
        'Everything Xcode and SwiftPM compile.',
        ['DerivedData/', '.build/', '*.ipa', '*.dSYM.zip'],
      ),
      GitignoreSection(
        'Your Xcode settings',
        'Window layouts and breakpoints that are personal to you.',
        ['xcuserdata/', '*.xcuserstate', '.swiftpm/'],
      ),
      GitignoreSection(
        'CocoaPods',
        'Downloaded pods — `pod install` restores them.',
        ['Pods/'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'go',
    label: 'Go',
    summary: 'Compiled binaries and test output.',
    category: GitignoreCategory.project,
    markers: ['go.mod'],
    sections: [
      GitignoreSection(
        'Binaries',
        'Programs produced by `go build`.',
        ['bin/', '*.exe', '*.exe~', '*.dll', '*.so', '*.dylib'],
      ),
      GitignoreSection(
        'Test output',
        'Compiled tests and coverage profiles.',
        ['*.test', '*.out', 'go.work'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'rust',
    label: 'Rust',
    summary: 'Cargo’s build folder.',
    category: GitignoreCategory.project,
    markers: ['Cargo.toml'],
    sections: [
      GitignoreSection(
        'Build output',
        'Everything Cargo compiles — can be gigabytes.',
        ['target/', '**/*.rs.bk'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'dotnet',
    label: '.NET / C#',
    summary: 'bin/obj folders and Visual Studio user files.',
    category: GitignoreCategory.project,
    markerExtensions: ['.csproj', '.sln', '.fsproj'],
    sections: [
      GitignoreSection(
        'Build output',
        'Compiled assemblies.',
        ['bin/', 'obj/'],
      ),
      GitignoreSection(
        'Visual Studio',
        'Personal IDE state.',
        ['.vs/', '*.user', '*.suo'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'php',
    label: 'PHP / Composer',
    summary: 'Composer’s installed packages.',
    category: GitignoreCategory.project,
    markers: ['composer.json'],
    sections: [
      GitignoreSection(
        'Dependencies',
        '`composer install` brings these back.',
        ['vendor/'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'ruby',
    label: 'Ruby',
    summary: 'Bundler’s local gems and caches.',
    category: GitignoreCategory.project,
    markers: ['Gemfile'],
    sections: [
      GitignoreSection(
        'Dependencies',
        'Gems installed by Bundler.',
        ['.bundle/', 'vendor/bundle/'],
      ),
      GitignoreSection(
        'Temporary files',
        'Logs and tmp folders from Rails and friends.',
        ['log/', 'tmp/'],
      ),
    ],
  ),

  // --- Operating systems ----------------------------------------------------
  GitignoreTemplate(
    id: 'macos',
    label: 'macOS',
    summary: 'Invisible files Finder sprinkles into every folder.',
    category: GitignoreCategory.system,
    sections: [
      GitignoreSection(
        'Finder clutter',
        'Folder view settings and thumbnails — never part of your project.',
        ['.DS_Store', '.AppleDouble', '.LSOverride', '._*'],
      ),
      GitignoreSection(
        'Volume files',
        'Created on external drives.',
        ['.Spotlight-V100', '.Trashes', '.fseventsd'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'windows',
    label: 'Windows',
    summary: 'Thumbnail caches and folder settings from Explorer.',
    category: GitignoreCategory.system,
    sections: [
      GitignoreSection(
        'Explorer clutter',
        'Thumbnail caches and folder settings.',
        ['Thumbs.db', 'ehthumbs.db', 'Desktop.ini', r'$RECYCLE.BIN/'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'linux',
    label: 'Linux',
    summary: 'Backup and trash files from desktop environments.',
    category: GitignoreCategory.system,
    sections: [
      GitignoreSection(
        'Desktop clutter',
        'Editor backups and trash folders.',
        ['*~', '.directory', '.Trash-*'],
      ),
    ],
  ),

  // --- Good habits ----------------------------------------------------------
  GitignoreTemplate(
    id: 'secrets',
    label: 'Secrets',
    summary: 'Keeps passwords and API keys out of your history.',
    category: GitignoreCategory.habits,
    sections: [
      GitignoreSection(
        'Environment files',
        'API keys and passwords usually live here. A shareable example '
            'file is still allowed.',
        ['.env', '.env.*', '!.env.example'],
      ),
      GitignoreSection(
        'Private keys',
        'Certificates and signing keys.',
        ['*.pem', '*.key', '*.p12', '*.keystore', '*.jks'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'editors',
    label: 'Editors & IDEs',
    summary: 'Personal editor settings (VS Code, JetBrains, Vim).',
    category: GitignoreCategory.habits,
    sections: [
      GitignoreSection(
        'JetBrains',
        'IntelliJ, Android Studio and friends.',
        ['.idea/', '*.iml'],
      ),
      GitignoreSection(
        'VS Code',
        'Personal settings; shared recommendations are kept.',
        ['.vscode/*', '!.vscode/extensions.json', '!.vscode/settings.json'],
      ),
      GitignoreSection(
        'Vim & Emacs',
        'Swap and backup files.',
        ['*.swp', '*.swo', '\\#*\\#'],
      ),
    ],
  ),
  GitignoreTemplate(
    id: 'logs',
    label: 'Logs',
    summary: 'Log files that grow every time you run something.',
    category: GitignoreCategory.habits,
    sections: [
      GitignoreSection(
        'Logs',
        'Useful while debugging, noise in history.',
        ['*.log', 'logs/'],
      ),
    ],
  ),
];

GitignoreTemplate? gitignoreTemplateById(String id) {
  for (final t in gitignoreTemplates) {
    if (t.id == id) return t;
  }
  return null;
}

/// Suggests templates from the names in a folder's top level.
Set<String> detectGitignoreTemplates(Iterable<String> topLevelNames) {
  final names = topLevelNames.toSet();
  final lower = names.map((n) => n.toLowerCase()).toList();
  return {
    for (final t in gitignoreTemplates)
      if (t.markers.any(names.contains) ||
          t.markerExtensions.any(
            (ext) => lower.any((n) => n.endsWith(ext.toLowerCase())),
          ))
        t.id,
  };
}

/// Patterns in [content] (ignores comments and blank lines).
Set<String> gitignoreRules(String content) => {
  for (final line in content.split('\n'))
    if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#')) line.trim(),
};

/// Builds the text to write.
///
/// Without [existing], returns a complete, commented `.gitignore`. With
/// [existing], returns only a block to append, containing just the rules
/// the file doesn't have yet — or an empty string if nothing is new.
String buildGitignore(
  List<GitignoreTemplate> templates, {
  List<String> custom = const [],
  String? existing,
}) {
  final seen = existing == null ? <String>{} : gitignoreRules(existing);
  final out = StringBuffer();
  var added = 0;

  void section(String heading, String? why, Iterable<String> patterns) {
    final fresh = [
      for (final pattern in patterns)
        if (seen.add(pattern.trim())) pattern.trim(),
    ];
    if (fresh.isEmpty) return;
    if (out.isNotEmpty) out.writeln();
    out.writeln('# $heading');
    if (why != null) out.writeln('# $why');
    fresh.forEach(out.writeln);
    added += fresh.length;
  }

  for (final t in templates) {
    for (final s in t.sections) {
      section('${t.label} — ${s.title}', s.why.replaceAll('\n', ' '), s.patterns);
    }
  }
  section(
    'Your own rules',
    null,
    custom.map((c) => c.trim()).where((c) => c.isNotEmpty),
  );

  if (added == 0) return '';
  final header = existing == null
      ? '# .gitignore — created with Gitty.\n'
            '# Files matching these rules stay on your computer but are never '
            'committed.\n'
            '# Edit freely: one pattern per line, "#" starts a comment, '
            '"!" re-includes.\n\n'
      : '\n# ── Added by Gitty ──\n';
  return '$header$out';
}
