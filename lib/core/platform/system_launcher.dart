import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

import '../errors/gitty_exception.dart';

/// Opens things outside Gitty: terminal, editor, file manager, browser.
class SystemLauncher {
  const SystemLauncher();

  Future<void> openTerminal(String directory) async {
    if (Platform.isMacOS) {
      await _run('open', ['-a', 'Terminal', directory]);
    } else if (Platform.isWindows) {
      // Prefer Windows Terminal, fall back to classic cmd.
      final ok = await _tryStart('wt.exe', ['-d', directory]);
      if (!ok) {
        await _run('cmd.exe', [
          '/c',
          'start',
          'cmd.exe',
          '/K',
          'cd /d "$directory"',
        ], runInShell: true);
      }
    } else {
      const candidates = <(String, List<String> Function(String))>[
        ('x-terminal-emulator', _noArgs),
        ('gnome-terminal', _gnomeArgs),
        ('konsole', _konsoleArgs),
        ('xfce4-terminal', _xfceArgs),
        ('kitty', _noArgs),
        ('alacritty', _noArgs),
      ];
      for (final (exe, args) in candidates) {
        if (await _tryStart(exe, args(directory), workingDirectory: directory))
          return;
      }
      throw const GittyException("Couldn't find a terminal app to open.");
    }
  }

  static List<String> _noArgs(String _) => const [];
  static List<String> _gnomeArgs(String d) => ['--working-directory=$d'];
  static List<String> _konsoleArgs(String d) => ['--workdir', d];
  static List<String> _xfceArgs(String d) => ['--working-directory=$d'];

  Future<void> openInVsCode(String directory) async {
    // The `code` CLI is often not on a GUI app's PATH, so try known locations.
    final candidates = <String>[
      if (Platform.isMacOS) ...[
        '/usr/local/bin/code',
        '/opt/homebrew/bin/code',
        '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code',
      ],
      'code',
    ];
    for (final exe in candidates) {
      if (exe.startsWith('/') && !File(exe).existsSync()) continue;
      if (await _tryStart(exe, [directory], runInShell: Platform.isWindows))
        return;
    }
    if (Platform.isMacOS &&
        await _tryRun('open', ['-a', 'Visual Studio Code', directory]))
      return;
    throw const GittyException(
      "Couldn't open VS Code.",
      hint:
          'Install VS Code and enable the "code" command (Shell Command: Install \'code\' command in PATH).',
    );
  }

  Future<void> revealInFileManager(String directory) async {
    if (Platform.isMacOS) {
      await _run('open', [directory]);
    } else if (Platform.isWindows) {
      await _tryStart('explorer.exe', [directory]);
    } else {
      await _run('xdg-open', [directory]);
    }
  }

  Future<void> openUrl(Uri url) async {
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok)
      throw GittyException(
        "Couldn't open your browser.",
        details: url.toString(),
      );
  }

  Future<void> _run(
    String exe,
    List<String> args, {
    bool runInShell = false,
  }) async {
    final ok = await _tryRun(exe, args, runInShell: runInShell);
    if (!ok)
      throw GittyException(
        "Couldn't open that.",
        details: '$exe ${args.join(' ')}',
      );
  }

  Future<bool> _tryRun(
    String exe,
    List<String> args, {
    bool runInShell = false,
  }) async {
    try {
      final r = await Process.run(exe, args, runInShell: runInShell);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Starts a detached process; true if it launched.
  Future<bool> _tryStart(
    String exe,
    List<String> args, {
    String? workingDirectory,
    bool runInShell = false,
  }) async {
    try {
      await Process.start(
        exe,
        args,
        workingDirectory: workingDirectory,
        runInShell: runInShell,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
