/// Plain data models for the Git service layer. No Flutter imports here so the
/// layer can be reused (and unit-tested) anywhere, including a future mobile
/// build that talks to a different backend.
library;

import '../../core/errors/gitty_exception.dart';

/// How the current branch relates to its upstream.
enum SyncState {
  upToDate,
  ahead,
  behind,
  diverged,

  /// The branch has no upstream configured (never pushed).
  noUpstream,

  /// HEAD is not on a branch.
  detached,
}

enum FileChangeKind {
  modified,
  added,
  deleted,
  renamed,
  copied,
  typeChanged,
  untracked,
  conflicted,
}

/// One changed path in the working tree and/or index.
class FileChange {
  const FileChange({
    required this.path,
    required this.kind,
    required this.staged,
    required this.unstaged,
    this.originalPath,
  });

  final String path;

  /// Previous path for renames/copies.
  final String? originalPath;
  final FileChangeKind kind;

  /// The index (staging area) has changes for this path.
  final bool staged;

  /// The working tree has changes that are not staged yet.
  final bool unstaged;

  bool get isUntracked => kind == FileChangeKind.untracked;
  bool get isConflicted => kind == FileChangeKind.conflicted;

  @override
  String toString() =>
      'FileChange($path, $kind, staged: $staged, unstaged: $unstaged)';
}

class CommitInfo {
  const CommitInfo({
    required this.hash,
    required this.subject,
    required this.author,
    required this.date,
  });

  final String hash;
  final String subject;
  final String author;
  final DateTime date;

  String get shortHash => hash.length > 7 ? hash.substring(0, 7) : hash;
}

/// Result of `git status`.
class RepoStatus {
  const RepoStatus({
    required this.branch,
    required this.upstream,
    required this.ahead,
    required this.behind,
    required this.changes,
    this.headOid,
  });

  /// Current branch name, or null when HEAD is detached.
  final String? branch;

  /// e.g. `origin/main`, or null if the branch has no upstream.
  final String? upstream;
  final int ahead;
  final int behind;
  final List<FileChange> changes;

  /// Commit id of HEAD, or null for a brand-new repository with no commits.
  final String? headOid;

  bool get isDetached => branch == null;
  bool get hasCommits => headOid != null;
  bool get isClean => changes.isEmpty;

  int get stagedCount => changes.where((c) => c.staged).length;
  int get unstagedCount => changes.where((c) => c.unstaged).length;
  int get untrackedCount => changes.where((c) => c.isUntracked).length;
  int get conflictCount => changes.where((c) => c.isConflicted).length;

  SyncState get syncState {
    if (isDetached) return SyncState.detached;
    if (upstream == null) return SyncState.noUpstream;
    if (ahead > 0 && behind > 0) return SyncState.diverged;
    if (ahead > 0) return SyncState.ahead;
    if (behind > 0) return SyncState.behind;
    return SyncState.upToDate;
  }
}

/// Everything the dashboard needs to know about one repository.
class RepoSnapshot {
  const RepoSnapshot({
    required this.status,
    required this.lastCommit,
    this.remoteBranch,
  });

  final RepoStatus status;
  final CommitInfo? lastCommit;

  /// When the current branch isn't linked to an upstream but a branch with
  /// the same name exists on a remote (e.g. `origin/main`): that branch.
  /// The branch *is* online — it just needs linking.
  final String? remoteBranch;
}

/// Branch list for the "Switch branch" flow.
class BranchList {
  const BranchList({required this.local, required this.remoteOnly});

  final List<String> local;

  /// Remote branches (without the `origin/` prefix) that have no local
  /// counterpart yet. `git switch <name>` creates a tracking branch for them.
  final List<String> remoteOnly;
}

enum PullStrategy {
  /// `git pull --ff-only` — never creates merge commits or rewrites history.
  fastForwardOnly,

  /// `git pull --rebase` — replays local commits on top of the remote.
  rebase,

  /// `git pull --no-rebase` — merges the remote into the local branch.
  merge,
}

/// What happened when a remote (usually `origin`) was connected.
class RemoteConnection {
  const RemoteConnection({
    required this.remote,
    this.remoteIsEmpty = false,
    this.adoptedBranch,
    this.linkedBranch,
    this.fetchError,
    this.adoptError,
  });

  final String remote;

  /// The remote exists but has no branches yet (e.g. a new GitHub repo).
  final bool remoteIsEmpty;

  /// A fresh local repository started from this remote branch.
  final String? adoptedBranch;

  /// An existing local branch was linked to the same-named remote branch.
  final String? linkedBranch;

  /// The remote was saved but couldn't be reached yet.
  final GittyException? fetchError;

  /// The remote branch couldn't be checked out (local files in the way).
  final GittyException? adoptError;
}

/// What a set of .gitignore rules would change, computed before writing.
class GitignorePreview {
  const GitignorePreview({required this.newlyHidden, required this.stillTracked});

  /// Untracked paths that show up as changes today but would be hidden.
  /// Folders end with `/` (their contents are hidden with them).
  final List<String> newlyHidden;

  /// Already-committed files that match the rules. Git keeps tracking these
  /// until they're removed from the index.
  final List<String> stillTracked;

  int get hiddenFolders => newlyHidden.where((p) => p.endsWith('/')).length;
  int get hiddenFiles => newlyHidden.length - hiddenFolders;
}

/// Who commits in a repository, and where Git found that setting.
class GitIdentity {
  const GitIdentity({this.name, this.email, this.nameScope, this.emailScope});

  final String? name;
  final String? email;

  /// `local` (this repository), `global`, `system`, … or null when unset.
  final String? nameScope;
  final String? emailScope;

  bool get isComplete =>
      (name?.trim().isNotEmpty ?? false) && (email?.trim().isNotEmpty ?? false);

  /// Both values come from this repository's own config.
  bool get isLocal => nameScope == 'local' && emailScope == 'local';
}

/// One branch in the "family tree" shown in the Switch branch dialog.
class BranchNode {
  const BranchNode({
    required this.name,
    this.parent,
    this.isRoot = false,
    this.isCurrent = false,
    this.isRemoteOnly = false,
    this.parentIsGuess = false,
    this.ahead = 0,
    this.behind = 0,
    this.forkedAt,
    this.lastCommitAt,
  });

  final String name;

  /// The branch this one grew from (null for the trunk).
  final String? parent;
  final bool isRoot;
  final bool isCurrent;

  /// Exists only on the remote (switching creates a local copy).
  final bool isRemoteOnly;

  /// Worked out from history rather than recorded when it was created.
  final bool parentIsGuess;

  /// Commits this branch has that its parent doesn't.
  final int ahead;

  /// Commits the parent got since this branch grew from it.
  final int behind;

  /// When it split off from its parent (the fork commit's date).
  final DateTime? forkedAt;
  final DateTime? lastCommitAt;
}

class BranchTree {
  const BranchTree({required this.root, required this.nodes});

  /// The trunk (usually main/master), or null when there are no branches.
  final String? root;
  final List<BranchNode> nodes;

  BranchNode? node(String name) {
    for (final n in nodes) {
      if (n.name == name) return n;
    }
    return null;
  }

  /// Children of [name], most recently active first.
  List<BranchNode> childrenOf(String name) {
    final kids = nodes.where((n) => n.parent == name).toList();
    kids.sort((a, b) {
      final da = a.lastCommitAt ?? DateTime(0);
      final db = b.lastCommitAt ?? DateTime(0);
      return db.compareTo(da);
    });
    return kids;
  }
}

/// A remote branch that changed during a fetch.
class RemoteUpdate {
  const RemoteUpdate({
    required this.remoteRef,
    required this.branch,
    required this.newCommits,
    required this.authors,
    this.isNewBranch = false,
    this.rewritten = false,
    this.tip,
  });

  /// e.g. `origin/main`.
  final String remoteRef;

  /// e.g. `main`.
  final String branch;
  final int newCommits;

  /// Who wrote the new commits (distinct names, newest first).
  final List<String> authors;
  final bool isNewBranch;

  /// History was rewritten (force-push) rather than extended.
  final bool rewritten;
  final String? tip;
}

/// How the current branch relates to the branch it grew from.
class ParentSync {
  const ParentSync({
    required this.branch,
    required this.parent,
    required this.parentRef,
    required this.behind,
    this.parentTip,
  });

  final String branch;
  final String parent;

  /// What we compare against: `origin/main` when it exists, else `main`.
  final String parentRef;

  /// New commits on the parent that this branch doesn't have yet.
  final int behind;
  final String? parentTip;
}

/// Where a repository's remote is hosted, for logos and "open in browser".
enum RemoteHostKind {
  github('GitHub'),
  gitlab('GitLab'),
  bitbucket('Bitbucket'),
  azure('Azure DevOps'),
  otherGit('Git server'),
  localFolder('Folder on this computer');

  const RemoteHostKind(this.label);
  final String label;
}

class RemoteHost {
  const RemoteHost({
    required this.kind,
    required this.url,
    this.host,
    this.webUrl,
    this.remoteName = 'origin',
  });

  final RemoteHostKind kind;

  /// The raw remote URL.
  final String url;

  /// e.g. `gitlab.com` (null for local folders).
  final String? host;

  /// Browser address of the repository, when it can be worked out.
  final Uri? webUrl;
  final String remoteName;

  /// "GitLab", or the host name for other servers.
  String get label => kind == RemoteHostKind.otherGit && host != null
      ? host!
      : kind.label;

  /// Recognises GitHub, GitLab, Bitbucket and Azure DevOps (including
  /// self-hosted GitLab on e.g. `gitlab.mycompany.com`) from https, ssh and
  /// scp-style (`git@host:owner/repo.git`) URLs.
  static RemoteHost parse(String url, {String remoteName = 'origin'}) {
    final raw = url.trim();
    String? host;
    var path = '';

    final scp = RegExp(r'^(?:[^@/\s]+@)?([^:/\s]+):(?!//)(.+)$').firstMatch(raw);
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      host = uri.host.toLowerCase();
      path = uri.path;
    } else if (scp != null &&
        scp.group(1)!.length > 1 && // "C:/repos" is a Windows drive, not a host
        !raw.startsWith('/') &&
        !raw.contains(r'\')) {
      host = scp.group(1)!.toLowerCase();
      path = scp.group(2)!;
    } else {
      return RemoteHost(
        kind: RemoteHostKind.localFolder,
        url: raw,
        remoteName: remoteName,
      );
    }

    path = path.replaceFirst(RegExp(r'^/+'), '').replaceFirst(RegExp(r'\.git/?$'), '');
    final kind = host.contains('github')
        ? RemoteHostKind.github
        : host.contains('gitlab')
        ? RemoteHostKind.gitlab
        : host.contains('bitbucket')
        ? RemoteHostKind.bitbucket
        : host.contains('dev.azure.com') || host.contains('visualstudio.com')
        ? RemoteHostKind.azure
        : RemoteHostKind.otherGit;

    Uri? web;
    if (kind == RemoteHostKind.azure) {
      // ssh: git@ssh.dev.azure.com:v3/org/project/repo
      final parts = path.split('/');
      if (parts.length == 4 && parts.first == 'v3') {
        web = Uri.parse(
          'https://dev.azure.com/${parts[1]}/${parts[2]}/_git/${parts[3]}',
        );
      } else {
        web = Uri.tryParse('https://${host.replaceFirst('ssh.', '')}/$path');
      }
    } else if (path.isNotEmpty) {
      final webHost = host.startsWith('ssh.') ? host.substring(4) : host;
      web = Uri.tryParse('https://$webHost/$path');
    }
    return RemoteHost(
      kind: kind,
      url: raw,
      host: host.startsWith('ssh.') ? host.substring(4) : host,
      webUrl: web,
      remoteName: remoteName,
    );
  }
}

/// What Gitty found out about a git lock file.
class GitLockInfo {
  const GitLockInfo({
    required this.path,
    required this.exists,
    this.modified,
    this.inUse,
  });

  final String path;

  /// False when the lock disappeared on its own (the other program finished).
  final bool exists;
  final DateTime? modified;

  /// True: something is using it. False: nothing is — a leftover.
  /// Null: couldn't check (e.g. on Windows).
  final bool? inUse;

  Duration? get age =>
      modified == null ? null : DateTime.now().difference(modified!);

  /// Safe to delete: nothing holds it and it isn't brand new.
  bool get isLeftover =>
      exists &&
      inUse == false &&
      (age == null || age! > const Duration(seconds: 3));
}
