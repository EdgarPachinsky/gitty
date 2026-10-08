import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/errors/gitty_exception.dart';

class GitCommandResult {
  const GitCommandResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

/// Thin, safe wrapper around the system `git` binary.
///
/// - Never prompts for credentials (would hang a GUI app).
/// - Enforces a timeout and kills runaway processes.
/// - Translates common failures into friendly [GittyException]s.
class GitCli {
  GitCli({String? executable}) : _explicitExecutable = executable;

  final String? _explicitExecutable;
  String? _resolved;

  static const defaultTimeout = Duration(minutes: 2);
  static const networkTimeout = Duration(minutes: 5);

  /// Staging a large tree (many new files) can take a while.
  static const stagingTimeout = Duration(minutes: 10);

  /// GUI apps on macOS start with a minimal PATH, so prefer well-known install
  /// locations (Homebrew first, then Xcode CLT) before falling back to PATH.
  String get executable {
    if (_explicitExecutable != null) return _explicitExecutable;
    return _resolved ??= _resolveExecutable();
  }

  static String _resolveExecutable() {
    if (Platform.isMacOS || Platform.isLinux) {
      const candidates = [
        '/opt/homebrew/bin/git',
        '/usr/local/bin/git',
        '/usr/bin/git',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) return c;
      }
    }
    return 'git';
  }

  Map<String, String> get _environment => const {
    // Fail fast instead of waiting for a username/password prompt.
    'GIT_TERMINAL_PROMPT': '0',
    // Don't take optional locks during `status`, so we never block the
    // user's own terminal git commands.
    'GIT_OPTIONAL_LOCKS': '0',
    // English messages so our error mapping works.
    'LANGUAGE': 'en',
  };

  /// Runs `git <args>` in [workingDirectory].
  ///
  /// Throws a [GittyException] on non-zero exit unless [throwOnError] is false.
  /// [environment] is merged on top of Gitty's defaults (used e.g. to hand a
  /// GitHub token to git without putting it on the command line).
  Future<GitCommandResult> run(
    List<String> args, {
    required String workingDirectory,
    bool throwOnError = true,
    Duration timeout = defaultTimeout,
    Map<String, String>? environment,
  }) async {
    if (!Directory(workingDirectory).existsSync()) {
      throw GittyException(
        "That folder doesn't seem to exist anymore.",
        hint:
            'It may have been moved or deleted. You can remove it from Gitty.',
        details: workingDirectory,
      );
    }

    final Process process;
    try {
      process = await Process.start(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: environment == null
            ? _environment
            : {..._environment, ...environment},
      );
    } on ProcessException catch (e) {
      throw GittyException(
        "Gitty couldn't find Git on this computer.",
        hint:
            'Install Git from git-scm.com (on macOS: run "xcode-select --install"), then restart Gitty.',
        details: e.message,
      );
    }

    final started = DateTime.now();

    // Close stdin so git never waits for input.
    unawaited(process.stdin.close());

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      // Don't leave a lock behind for the next command (or the user) to trip
      // over — but only one this very command created.
      await _removeLockLeftBy(process, workingDirectory, started);
      throw GittyException(
        'Git is taking too long, so Gitty stopped it.',
        hint: 'Check your network connection or try again.',
        details: 'git ${args.join(' ')} timed out after ${timeout.inSeconds}s',
      );
    }

    final result = GitCommandResult(
      exitCode,
      await stdoutFuture,
      await stderrFuture,
    );
    if (throwOnError && !result.ok) {
      throw mapGitError(args, result);
    }
    return result;
  }

  static Future<void> _removeLockLeftBy(
    Process process,
    String workingDirectory,
    DateTime started,
  ) async {
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
    }
    final sep = Platform.pathSeparator;
    final lock = File('$workingDirectory$sep.git${sep}index.lock');
    try {
      if (lock.existsSync() &&
          !lock.lastModifiedSync().isBefore(
            started.subtract(const Duration(seconds: 1)),
          )) {
        lock.deleteSync();
      }
    } catch (_) {
      // Best-effort.
    }
  }

  /// `git --version`, or null when git is unavailable.
  Future<String?> version() async {
    try {
      final r = await run(
        ['--version'],
        workingDirectory: Directory.systemTemp.path,
        timeout: const Duration(seconds: 10),
      );
      return r.stdout.trim();
    } catch (_) {
      return null;
    }
  }
}

/// Maps git's stderr to a calm, actionable message.
GittyException mapGitError(List<String> args, GitCommandResult r) {
  final raw = (r.stderr.trim().isNotEmpty ? r.stderr : r.stdout).trim();
  final text = raw.toLowerCase();
  final details = 'git ${args.join(' ')}\n\n$raw';

  GittyException e(String message, [String? hint]) =>
      GittyException(message, hint: hint, details: details);

  final lock = RegExp(
    r"unable to create '([^']+\.lock)': file exists",
    caseSensitive: false,
  ).firstMatch(raw);
  if (lock != null) {
    return RepoLockedException(lockPath: lock.group(1)!, details: details);
  }
  if (text.contains('not a git repository')) {
    return e("This folder isn't a Git repository.");
  }
  if (text.contains('please tell me who you are') ||
      text.contains('unable to auto-detect email') ||
      text.contains('author identity unknown') ||
      text.contains('empty ident name')) {
    return MissingIdentityException(details: details);
  }
  if (text.contains('nothing to commit') ||
      text.contains('no changes added to commit')) {
    return e(
      "There's nothing staged to commit yet.",
      'Stage some files first.',
    );
  }
  // The server answered and said no: a permissions problem, not the
  // network. (Checked before the generic "unable to access" below.)
  if (text.contains('returned error: 403') ||
      text.contains('write access to repository not granted') ||
      RegExp(r'permission to \S+ denied').hasMatch(text)) {
    final pushing = args.contains('push');
    return e(
      pushing
          ? "You don't have permission to push to this repository."
          : "You don't have access to this repository.",
      'Your internet is fine — the server answered, but the account being '
          'used isn’t allowed ${pushing ? 'to write here' : 'to see it'}. '
          'In Settings → GitHub, connect the account that owns this '
          'repository, or ask its owner to add you as a collaborator.',
    );
  }
  if (text.contains('returned error: 401') ||
      text.contains('terminal prompts disabled') ||
      text.contains('could not read username') ||
      text.contains('authentication failed') ||
      text.contains('invalid username or password')) {
    return e(
      'Git needs your credentials for this remote.',
      'Sign in once from a terminal (e.g. git push) or set up a credential helper, then try again.',
    );
  }
  if (text.contains('permission denied (publickey)')) {
    return e(
      "The remote didn't accept your SSH key.",
      'Make sure your SSH key is added to your Git host and loaded in ssh-agent.',
    );
  }
  if (text.contains('could not resolve host') ||
      text.contains('failed to connect') ||
      text.contains("couldn't connect") ||
      text.contains('connection refused') ||
      text.contains('connection timed out') ||
      text.contains('operation timed out') ||
      text.contains('network is unreachable')) {
    return e(
      "Couldn't reach the remote.",
      'Check your internet connection and try again.',
    );
  }
  if (text.contains('unable to access')) {
    // Reached the server, but it refused for another reason.
    return e(
      "The remote refused the request.",
      'See details for exactly what the server said.',
    );
  }
  if (text.contains('without `workflow` scope') ||
      text.contains('without workflow scope')) {
    return e(
      'GitHub needs one more permission to update workflow files.',
      'Disconnect GitHub in Settings and connect again, then push once more.',
    );
  }
  if (text.contains('refusing to merge unrelated histories')) {
    return e(
      'Your local work and the remote started separately.',
      'They share no history yet. Combine them from a terminal with: git pull --allow-unrelated-histories',
    );
  }
  if (text.contains('[rejected]') ||
      text.contains('non-fast-forward') ||
      text.contains('fetch first')) {
    return e(
      'The remote has commits you don\'t have yet.',
      'Pull first, then push again.',
    );
  }
  if (text.contains('not possible to fast-forward') ||
      text.contains('divergent branches') ||
      text.contains('need to specify how to reconcile')) {
    return e(
      'Your branch and the remote have both changed.',
      'Choose "Pull + Rebase" or "Pull + Merge" to combine them.',
    );
  }
  if (text.contains('would be overwritten') ||
      text.contains('cannot pull with rebase') ||
      text.contains('your local changes')) {
    return LocalChangesException(details: details);
  }
  if (text.contains('conflict')) {
    return e(
      'Some changes clash and need a human touch.',
      'Use “Resolve conflicts” in the changes list to pick what to keep.',
    );
  }
  if (text.contains('already exists')) {
    return e('Something with that name already exists.');
  }
  if (text.contains('is not a valid branch name') ||
      text.contains('not a valid ref')) {
    return e(
      "That isn't a valid branch name.",
      'Use letters, numbers, dashes and slashes (e.g. feature/login).',
    );
  }
  if (text.contains('no configured push destination') ||
      text.contains('does not appear to be a git repository')) {
    return e(
      "This repository doesn't have a remote to sync with.",
      'Add a remote (e.g. origin) first.',
    );
  }
  if (text.contains('repository not found')) {
    return e(
      "Couldn't find that repository on the remote.",
      'Check the URL and your access rights.',
    );
  }
  return e('Git reported a problem.', 'See details for the full message.');
}
