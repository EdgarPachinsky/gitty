import 'dart:async';
import 'dart:io';

/// A user-facing error.
///
/// [message] is a short, calm sentence we can show as-is. [hint] tells the
/// user what to do next. [details] holds raw technical output (e.g. git's
/// stderr) for a "Show details" affordance.
class GittyException implements Exception {
  const GittyException(this.message, {this.hint, this.details});

  final String message;
  final String? hint;
  final String? details;

  @override
  String toString() => details == null ? message : '$message\n$details';
}

/// Turns any error into something friendly enough to show in the UI.
GittyException toGittyException(Object error) {
  if (error is GittyException) return error;
  if (error is SocketException) {
    return GittyException(
      "Couldn't reach the network.",
      hint: 'Check your internet connection and try again.',
      details: error.message,
    );
  }
  if (error is TimeoutException) {
    return const GittyException(
      'That took longer than expected.',
      hint: 'Please try again in a moment.',
    );
  }
  if (error is ProcessException) {
    return GittyException(
      "Couldn't run a required program.",
      hint: 'Make sure Git is installed and available on your PATH.',
      details: '${error.executable}: ${error.message}',
    );
  }
  return GittyException(
    'Something unexpected happened.',
    hint: 'Try again. If it keeps happening, check the details.',
    details: error.toString(),
  );
}

/// The folder is tracked by Gitty but isn't a Git repository (yet).
///
/// Any folder — empty or not — can be added to Gitty; the repository screen
/// offers to run `git init` when it sees this.
class NotARepositoryException extends GittyException {
  const NotARepositoryException(String path)
    : super(
        "This folder isn't using Git yet.",
        hint: 'Initialize Git to start keeping track of changes here.',
        details: path,
      );
}

/// Git refused to commit because it doesn't know the author's name/email.
/// The UI answers this by asking for them (saved for this repository only).
class MissingIdentityException extends GittyException {
  const MissingIdentityException({super.details})
    : super(
        'Git needs your name and email before it can commit.',
        hint: 'Add them for this repository and Gitty will commit right away.',
      );
}

/// Git couldn't take its lock file (e.g. `.git/index.lock`) because it
/// already exists — another git program is busy, or one stopped halfway and
/// left it behind. The UI checks which, and offers to clear a leftover.
class RepoLockedException extends GittyException {
  const RepoLockedException({required this.lockPath, super.details})
    : super(
        'Another Git program is busy with this repository.',
        hint: 'If nothing else is using it, Gitty can clear the leftover lock.',
      );

  /// Absolute path of the lock file, e.g. `/…/repo/.git/index.lock`.
  final String lockPath;
}

/// A switch, pull or similar would overwrite uncommitted edits, so Git
/// stopped. The UI offers to put the changes aside and carry on.
class LocalChangesException extends GittyException {
  const LocalChangesException({super.details})
    : super(
        'This would overwrite your uncommitted changes.',
        hint: 'Commit them, or put them aside for a moment, then try again.',
      );
}
