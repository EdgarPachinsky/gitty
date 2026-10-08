import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../core/errors/gitty_exception.dart';
import 'git_cli.dart';
import 'git_models.dart';
import 'history.dart';
import 'workflow_models.dart';
import 'repo_scanner.dart';
import 'status_parser.dart';

/// Returns the connected GitHub account's access token, or null.
typedef GitHubTokenReader = Future<String?> Function();

/// High-level Git operations used by the UI.
///
/// Everything goes through [GitCli] (the system `git` binary), which keeps
/// behaviour identical to what users get in their terminal — same config,
/// hooks, credential helpers and SSH keys.
class GitService {
  GitService(this._cli, {GitHubTokenReader? githubToken})
    : _githubToken = githubToken;

  final GitCli _cli;

  /// When a GitHub account is connected, network commands that GitHub
  /// rejects for lack of credentials are retried once with its token.
  final GitHubTokenReader? _githubToken;

  Future<String?> gitVersion() => _cli.version();

  // ---------------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------------

  /// Returns the repository root for [path], or null if it isn't inside a repo.
  Future<String?> findRepositoryRoot(String path) async {
    final r = await _cli.run(
      ['rev-parse', '--show-toplevel'],
      workingDirectory: path,
      throwOnError: false,
    );
    if (!r.ok) return null;
    final root = r.stdout.trim();
    return root.isEmpty ? null : p.normalize(root);
  }

  /// True when [path] is (inside) a Git repository.
  Future<bool> isRepository(String path) async {
    // Fast path: a `.git` directory (or file, for worktrees/submodules).
    if (FileSystemEntity.typeSync(p.join(path, '.git')) !=
        FileSystemEntityType.notFound) {
      return true;
    }
    return await findRepositoryRoot(path) != null;
  }

  // ---------------------------------------------------------------------------
  // Setting up
  // ---------------------------------------------------------------------------

  /// Runs `git init` in [path]. Existing files are left untouched.
  ///
  /// Uses `main` as the first branch unless the user configured
  /// `init.defaultBranch` themselves.
  Future<void> init(String path) async {
    final normalized = p.normalize(path);
    final home = RepoScanner.homeDirectory;
    if (p.rootPrefix(normalized) == normalized ||
        (home != null && p.equals(normalized, p.normalize(home)))) {
      throw GittyException(
        "Let's not turn this whole folder into a repository.",
        hint:
            'Pick a project folder instead — Git would track everything inside it.',
        details: normalized,
      );
    }
    final configured = await _cli.run(
      ['config', '--get', 'init.defaultBranch'],
      workingDirectory: path,
      throwOnError: false,
    );
    if (configured.ok && configured.stdout.trim().isNotEmpty) {
      await _cli.run(['init'], workingDirectory: path);
      return;
    }
    final r = await _cli.run(
      ['init', '--initial-branch=main'],
      workingDirectory: path,
      throwOnError: false,
    );
    if (r.ok) return;
    // Git older than 2.28 doesn't know --initial-branch.
    await _cli.run(['init'], workingDirectory: path);
  }

  /// Adds (or re-points) the remote [name] to [url], then tries to fetch it
  /// so Gitty can link the local branch to the remote one right away.
  Future<RemoteConnection> connectRemote(
    String repo,
    String url, {
    String name = 'origin',
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) {
      throw const GittyException(
        'That doesn\'t look like a repository URL.',
        hint: 'It usually looks like https://github.com/owner/repo.git',
      );
    }
    final existing = await remotes(repo);
    await _cli.run(
      existing.contains(name)
          ? ['remote', 'set-url', name, trimmed]
          : ['remote', 'add', name, trimmed],
      workingDirectory: repo,
    );

    try {
      await _network(['fetch', '--prune', name], workingDirectory: repo);
    } catch (e) {
      return RemoteConnection(
        remote: name,
        fetchError: toGittyException(e),
      );
    }

    final remoteBranch = await _remoteDefaultBranch(repo, name);
    if (remoteBranch == null) {
      return RemoteConnection(remote: name, remoteIsEmpty: true);
    }

    final s = await status(repo);
    if (!s.hasCommits) {
      // Fresh repository: take the remote's branch as our starting point.
      // Files already in the folder stay put (they show up as changes),
      // unless they'd be overwritten — then git refuses and nothing changes.
      final r = await _cli.run(
        ['checkout', '-B', remoteBranch, '--track', '$name/$remoteBranch'],
        workingDirectory: repo,
        throwOnError: false,
      );
      return RemoteConnection(
        remote: name,
        adoptedBranch: r.ok ? remoteBranch : null,
        adoptError: r.ok
            ? null
            : GittyException(
                'Connected to $name, but some files here also exist in the remote, so Gitty left your files as they were.',
                hint:
                    'Move those files out of the way, then use Pull — or commit and publish your own version.',
                details: r.stderr.trim(),
              ),
      );
    }

    final branch = s.branch;
    if (branch != null && s.upstream == null) {
      final remoteHasBranch = await _cli.run(
        ['rev-parse', '--verify', '--quiet', 'refs/remotes/$name/$branch'],
        workingDirectory: repo,
        throwOnError: false,
      );
      if (remoteHasBranch.ok) {
        await _cli.run(
          ['branch', '--set-upstream-to=$name/$branch', branch],
          workingDirectory: repo,
        );
        return RemoteConnection(remote: name, linkedBranch: branch);
      }
    }
    return RemoteConnection(remote: name);
  }

  /// The remote's default branch name (e.g. `main`), from already-fetched
  /// refs. Null when the remote has no branches yet.
  Future<String?> _remoteDefaultBranch(String repo, String remote) async {
    try {
      await _network(['remote', 'set-head', remote, '--auto'],
          workingDirectory: repo, timeout: const Duration(seconds: 60));
      final head = await _cli.run(
        ['symbolic-ref', '--short', 'refs/remotes/$remote/HEAD'],
        workingDirectory: repo,
        throwOnError: false,
      );
      final value = head.stdout.trim();
      if (head.ok && value.startsWith('$remote/')) {
        return value.substring(remote.length + 1);
      }
    } catch (_) {
      // Fall back to guessing from the fetched branches below.
    }
    final r = await _cli.run([
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/remotes/$remote',
    ], workingDirectory: repo);
    final names = [
      for (final ref in _lines(r.stdout))
        if (ref.startsWith('$remote/')) ref.substring(remote.length + 1),
    ]..remove('HEAD');
    if (names.isEmpty) return null;
    for (final preferred in ['main', 'master', 'trunk', 'develop']) {
      if (names.contains(preferred)) return preferred;
    }
    return names.first;
  }

  // ---------------------------------------------------------------------------
  // Reading state
  // ---------------------------------------------------------------------------

  Future<RepoStatus> status(String repo) async {
    final r = await _cli.run([
      'status',
      '--porcelain=v2',
      '--branch',
      '-z',
      '--untracked-files=all',
    ], workingDirectory: repo);
    final out = r.stdout;
    // Thousands of changed/untracked files make a big output; parse that
    // off the UI thread so scrolling and animations stay smooth.
    if (out.length > _bigStatusOutput) return _parseStatusInBackground(out);
    return parsePorcelainV2(out);
  }

  Future<CommitInfo?> lastCommit(String repo) async {
    const sep = '\u001f';
    final r = await _cli.run(
      ['log', '-1', '--format=%H$sep%s$sep%an$sep%ct'],
      workingDirectory: repo,
      throwOnError: false, // fails on repos without commits
    );
    if (!r.ok) return null;
    final parts = r.stdout.trim().split(sep);
    if (parts.length < 4) return null;
    final seconds = int.tryParse(parts[3]) ?? 0;
    return CommitInfo(
      hash: parts[0],
      subject: parts[1],
      author: parts[2],
      date: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
    );
  }

  Future<RepoSnapshot> snapshot(String repo) async {
    final results = await Future.wait([status(repo), lastCommit(repo)]);
    final status0 = results[0] as RepoStatus;
    return RepoSnapshot(
      status: status0,
      lastCommit: results[1] as CommitInfo?,
      remoteBranch: status0.upstream == null && status0.branch != null
          ? await sameNameRemoteBranch(repo, status0.branch!)
          : null,
    );
  }

  /// `origin/<branch>` (or another remote's copy) when one exists locally.
  Future<String?> sameNameRemoteBranch(String repo, String branch) async {
    final r = await _cli.run(
      ['for-each-ref', '--format=%(refname:short)', 'refs/remotes/*/$branch'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final found = _lines(r.stdout);
    if (found.isEmpty) return null;
    return found.contains('origin/$branch') ? 'origin/$branch' : found.first;
  }

  /// Links [branch] to [remoteRef] (e.g. `origin/main`) so pull/push and the
  /// ahead/behind counts work — the same link `git clone` sets up.
  Future<void> linkUpstream(String repo, String branch, String remoteRef) =>
      _cli.run([
        'branch',
        '--set-upstream-to=$remoteRef',
        branch,
      ], workingDirectory: repo);

  /// Where the repository is hosted (prefers `origin`), or null without
  /// remotes.
  Future<RemoteHost?> remoteHost(String repo) async {
    final names = await remotes(repo);
    if (names.isEmpty) return null;
    final name = names.contains('origin') ? 'origin' : names.first;
    final r = await _cli.run(
      ['remote', 'get-url', name],
      workingDirectory: repo,
      throwOnError: false,
    );
    final url = r.stdout.trim();
    if (!r.ok || url.isEmpty) return null;
    return RemoteHost.parse(url, remoteName: name);
  }

  Future<List<String>> remotes(String repo) async {
    final r = await _cli.run(['remote'], workingDirectory: repo);
    return r.stdout
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  Future<BranchList> branches(String repo) async {
    final localR = await _cli.run([
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/heads',
    ], workingDirectory: repo);
    final remoteR = await _cli.run([
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/remotes',
    ], workingDirectory: repo);
    final local = _lines(localR.stdout)..sort();
    final localSet = local.toSet();
    final remoteOnly = <String>{};
    for (final ref in _lines(remoteR.stdout)) {
      final slash = ref.indexOf('/');
      if (slash < 0)
        continue; // bare remote name, e.g. "origin" for origin/HEAD
      final name = ref.substring(slash + 1);
      if (name == 'HEAD' || localSet.contains(name)) continue;
      remoteOnly.add(name);
    }
    return BranchList(local: local, remoteOnly: remoteOnly.toList()..sort());
  }

  /// Files whose diffs tell a model nothing (lockfiles, generated code, IDE
  /// state). They still appear in the file list, just not as diff text.
  static const noisyDiffGlobs = [
    '**/pubspec.lock',
    '**/package-lock.json',
    '**/yarn.lock',
    '**/pnpm-lock.yaml',
    '**/Podfile.lock',
    '**/Cargo.lock',
    '**/composer.lock',
    '**/Gemfile.lock',
    '**/poetry.lock',
    '**/go.sum',
    '**/*.g.dart',
    '**/*.freezed.dart',
    '**/*.min.js',
    '**/*.min.css',
    '**/*.map',
    '**/*.svg',
    '**/.idea/**',
    '**/*.xcodeproj/**',
    '**/*.xcworkspace/**',
    '**/Flutter/ephemeral/**',
    '**/GeneratedPluginRegistrant.*',
    '**/generated_plugin_registrant.*',
    '**/generated_plugins.cmake',
  ];

  /// Staged diff for commit-message generation: noise excluded, each file
  /// capped at [perFileChars] and the whole at [maxChars], so a local model
  /// isn't stuck reading thousands of lines.
  Future<String> stagedDiff(
    String repo, {
    int maxChars = 12000,
    int perFileChars = 2500,
  }) async {
    final r = await _cli.run([
      'diff',
      '--cached',
      '--no-color',
      '--no-ext-diff',
      '--unified=2',
      '--',
      '.',
      for (final glob in noisyDiffGlobs) ':(exclude,glob)$glob',
    ], workingDirectory: repo);
    return compactDiff(r.stdout, maxChars: maxChars, perFileChars: perFileChars);
  }

  /// Caps each file's part of [diff] and the total size, with friendly
  /// markers where text was left out.
  static String compactDiff(
    String diff, {
    required int maxChars,
    required int perFileChars,
  }) {
    if (diff.length <= maxChars && perFileChars >= maxChars) return diff;
    final files = diff
        .split(RegExp(r'(?=^diff --git )', multiLine: true))
        .where((f) => f.trim().isNotEmpty);
    final out = StringBuffer();
    for (final file in files) {
      var part = file;
      if (part.length > perFileChars) {
        final hidden = '\n'.allMatches(part.substring(perFileChars)).length;
        part =
            '${part.substring(0, perFileChars)}\n[… $hidden more lines in this file]\n';
      }
      if (out.length + part.length > maxChars) {
        out.writeln('[… more files changed — see the file list above]');
        break;
      }
      out.write(part);
    }
    return out.toString();
  }

  Future<String> stagedDiffStat(String repo) async {
    final r = await _cli.run([
      'diff',
      '--cached',
      '--no-color',
      '--stat',
    ], workingDirectory: repo);
    return r.stdout.trim();
  }

  // ---------------------------------------------------------------------------
  // Staging & committing
  // ---------------------------------------------------------------------------

  Future<void> stageAll(String repo) => _cli.run(
    ['add', '--all'],
    workingDirectory: repo,
    timeout: GitCli.stagingTimeout,
  );

  Future<void> stage(String repo, List<String> paths) async {
    if (paths.isEmpty) return;
    await _cli.run(
      ['add', '--all', '--', ...paths],
      workingDirectory: repo,
      timeout: GitCli.stagingTimeout,
    );
  }

  Future<void> unstage(String repo, List<String> paths) async {
    if (paths.isEmpty) return;
    await _cli.run(['reset', '-q', '--', ...paths], workingDirectory: repo);
  }

  Future<void> unstageAll(String repo) =>
      _cli.run(['reset', '-q'], workingDirectory: repo);

  /// Commits staged changes and returns the new commit's short hash.
  Future<String> commit(String repo, String message) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      throw const GittyException('Please write a commit message first.');
    }
    await _cli.run(['commit', '-m', trimmed], workingDirectory: repo);
    final r = await _cli.run([
      'rev-parse',
      '--short',
      'HEAD',
    ], workingDirectory: repo);
    return r.stdout.trim();
  }

  // ---------------------------------------------------------------------------
  // Syncing
  // ---------------------------------------------------------------------------

  Future<void> fetch(String repo) =>
      _network(['fetch', '--all', '--prune'], workingDirectory: repo);

  Future<void> pull(String repo, PullStrategy strategy) {
    final args = switch (strategy) {
      PullStrategy.fastForwardOnly => ['pull', '--ff-only'],
      PullStrategy.rebase => ['pull', '--rebase', '--autostash'],
      PullStrategy.merge => ['pull', '--no-rebase', '--no-edit'],
    };
    return _network(args, workingDirectory: repo);
  }

  /// Pushes the current branch. If it has no upstream yet, publishes it to the
  /// first remote (preferring `origin`) and sets the upstream.
  Future<void> push(String repo) async {
    final s = await status(repo);
    if (s.isDetached) {
      throw const GittyException(
        "You're not on a branch right now, so there's nothing to push.",
        hint: 'Switch to a branch (or create one) first.',
      );
    }
    if (s.upstream != null) {
      await _network(['push'], workingDirectory: repo);
      return;
    }
    final allRemotes = await remotes(repo);
    if (allRemotes.isEmpty) {
      throw const GittyException(
        "This repository doesn't have a remote to push to.",
        hint: 'Add one with: git remote add origin <url>',
      );
    }
    final remote = allRemotes.contains('origin') ? 'origin' : allRemotes.first;
    await _network([
      'push',
      '--set-upstream',
      remote,
      s.branch!,
    ], workingDirectory: repo);
  }

  // ---------------------------------------------------------------------------
  // History
  // ---------------------------------------------------------------------------

  /// What was done in this repository (newest first), from Git's reflog:
  /// commits, switches, pulls, pushes, new branches… — from Gitty, a
  /// terminal or an editor alike. Git keeps about 90 days of it.
  Future<List<ActivityEvent>> activity(String repo, {int limit = 400}) async {
    final r = await _cli.run(
      ['rev-parse', '--absolute-git-dir', '--git-common-dir'],
      workingDirectory: repo,
    );
    final lines = _lines(r.stdout);
    if (lines.isEmpty) return const [];
    final gitDir = lines.first;
    final common = lines.length > 1
        ? (p.isAbsolute(lines[1]) ? lines[1] : p.join(repo, lines[1]))
        : gitDir;
    final current = await currentBranch(repo);
    return _activityInBackground(
      p.normalize(gitDir),
      p.normalize(common),
      current,
      limit,
    );
  }

  /// Commits of the current branch (newest first), plus — when it's linked
  /// online — the linked branch's commits you haven't downloaded yet.
  Future<List<HistoryCommit>> commitHistory(
    String repo, {
    String? upstream,
    int limit = 150,
  }) async {
    final hasHead = (await _cli.run(
      ['rev-parse', '--verify', '-q', 'HEAD'],
      workingDirectory: repo,
      throwOnError: false,
    )).ok;
    if (!hasHead) return const [];

    final r = await _cli.run([
      'log',
      '--format=$commitLogFormat',
      '-n',
      '$limit',
      'HEAD',
      if (upstream != null) upstream,
      '--',
    ], workingDirectory: repo);
    final commits = await _commitLogInBackground(r.stdout);

    Future<Set<String>> revs(List<String> range) async {
      final out = await _cli.run(
        ['rev-list', '-n', '$limit', ...range],
        workingDirectory: repo,
        throwOnError: false,
      );
      return _lines(out.stdout).toSet();
    }

    final Set<String> notPushed;
    final Set<String> onlineOnly;
    if (upstream != null) {
      notPushed = await revs(['$upstream..HEAD']);
      onlineOnly = await revs(['HEAD..$upstream']);
    } else {
      // Not linked yet: anything that isn't on any online branch.
      notPushed = (await remotes(repo)).isEmpty
          ? const {}
          : await revs(['HEAD', '--not', '--remotes']);
      onlineOnly = const {};
    }
    return [
      for (final c in commits)
        c.copyWith(
          notPushed: notPushed.contains(c.hash),
          onlineOnly: onlineOnly.contains(c.hash),
        ),
    ];
  }

  /// Full message body and changed files of one commit.
  Future<CommitDetails> commitDetails(String repo, String hash) async {
    final r = await _cli.run([
      'show',
      '--format=%b%x1e',
      '--numstat',
      '-M',
      hash,
      '--',
    ], workingDirectory: repo);
    return parseCommitDetails(r.stdout);
  }

  // ---------------------------------------------------------------------------
  // Branches
  // ---------------------------------------------------------------------------

  /// Creates [name], starting from [from] (a local branch, or a branch that
  /// only exists online, e.g. `dev` → `origin/dev`). Without [from] it
  /// starts from where you are now.
  ///
  /// The new branch is never linked to its starting point, so Pull/Push
  /// don't accidentally target e.g. `origin/dev`; [publishBranch] links it
  /// to its own online copy.
  Future<void> createBranch(
    String repo,
    String name, {
    bool switchToIt = true,
    String? from,
  }) async {
    final current = await currentBranch(repo);
    String? startPoint;
    if (from != null && from != current) {
      final isLocal = (await _cli.run(
        ['show-ref', '--verify', '--quiet', 'refs/heads/$from'],
        workingDirectory: repo,
        throwOnError: false,
      )).ok;
      startPoint = isLocal ? from : await sameNameRemoteBranch(repo, from);
      if (startPoint == null) {
        throw GittyException(
          'Gitty couldn’t find the branch “$from”.',
          hint: 'Try Fetch to get the latest branches, then try again.',
        );
      }
    }
    final args = switchToIt
        ? ['switch', '--no-track', '-c', name, if (startPoint != null) startPoint]
        : ['branch', '--no-track', name, if (startPoint != null) startPoint];
    await _cli.run(args, workingDirectory: repo);
    // Remember where it grew from, for the branch tree (local config only).
    final parent = startPoint == null ? current : from;
    if (parent != null) {
      await _cli.run(
        ['config', '--local', 'branch.$name.$_parentKey', parent],
        workingDirectory: repo,
        throwOnError: false,
      );
    }
  }

  /// Puts [branch] online (prefers `origin`) and links it to that copy, so
  /// Pull/Push work for it. It doesn't need to be the current branch.
  /// Returns the remote's name.
  Future<String> publishBranch(String repo, String branch) async {
    final all = await remotes(repo);
    if (all.isEmpty) {
      throw const GittyException(
        "This repository isn't connected online yet, so there's nowhere to push.",
        hint: 'Use Publish on the repository screen to connect it first.',
      );
    }
    final remote = all.contains('origin') ? 'origin' : all.first;
    await _network([
      'push',
      '--set-upstream',
      remote,
      branch,
    ], workingDirectory: repo);
    return remote;
  }

  /// The checked-out branch, or null when HEAD is detached.
  Future<String?> currentBranch(String repo) async {
    final r = await _cli.run(
      ['symbolic-ref', '--short', '-q', 'HEAD'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final name = r.stdout.trim();
    return r.ok && name.isNotEmpty ? name : null;
  }

  /// The upstream of [branch] (e.g. `origin/main`), or null if none.
  Future<String?> upstreamOf(String repo, String branch) async {
    final r = await _cli.run(
      ['rev-parse', '--abbrev-ref', '$branch@{upstream}'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final value = r.stdout.trim();
    return r.ok && value.isNotEmpty ? value : null;
  }

  /// Joins [ref] (e.g. `origin/main`) into the current branch with a merge
  /// commit — nothing is rewritten.
  Future<void> mergeInto(String repo, String ref) => _cli.run([
    'merge',
    '--no-edit',
    ref,
  ], workingDirectory: repo);

  /// How many commits [ref] has that the current branch doesn't (0 when
  /// unknown).
  Future<int> commitsMissingFrom(String repo, String ref) async {
    final r = await _cli.run(
      ['rev-list', '--count', 'HEAD..$ref'],
      workingDirectory: repo,
      throwOnError: false,
    );
    return r.ok ? int.tryParse(r.stdout.trim()) ?? 0 : 0;
  }

  /// "Pull from another branch": brings [branch]'s changes into the current
  /// one. With [online], its latest version is downloaded first and that is
  /// used (like `git pull origin <branch>`). [rebase] puts your own commits
  /// on top instead of adding a merge commit. Returns how many commits came
  /// in (0 = nothing new).
  Future<int> pullFromBranch(
    String repo,
    String branch, {
    bool online = true,
    bool rebase = false,
  }) async {
    var ref = branch;
    if (online) {
      final all = await remotes(repo);
      if (all.isNotEmpty) {
        final remote = all.contains('origin') ? 'origin' : all.first;
        await _network(['fetch', remote, branch], workingDirectory: repo);
        ref = '$remote/$branch';
      }
    }
    final incoming = await commitsMissingFrom(repo, ref);
    if (incoming == 0) return 0;
    await _cli.run(
      rebase ? ['rebase', ref] : ['merge', '--no-edit', ref],
      workingDirectory: repo,
      environment: const {'GIT_EDITOR': 'true'},
    );
    return incoming;
  }

  // ---------------------------------------------------------------------------
  // Branch family tree
  // ---------------------------------------------------------------------------

  /// Config key (under `branch.<name>.`) where Gitty records a branch's
  /// parent. Git itself ignores it.
  static const _parentKey = 'gittyParent';

  static final _sha = RegExp(r'^[0-9a-f]{7,64}$');

  Future<Map<String, String>> _recordedParents(String repo) async {
    final r = await _cli.run(
      ['config', '--local', '--get-regexp', r'^branch\..*\.gittyparent$'],
      workingDirectory: repo,
      throwOnError: false,
    );
    const prefix = 'branch.';
    const suffix = '.gittyparent';
    final result = <String, String>{};
    for (final line in _lines(r.stdout)) {
      final space = line.indexOf(' ');
      if (space < 0) continue;
      final key = line.substring(0, space);
      if (!key.startsWith(prefix) || !key.toLowerCase().endsWith(suffix)) {
        continue;
      }
      final branch = key.substring(prefix.length, key.length - suffix.length);
      final parent = line.substring(space + 1).trim();
      if (branch.isNotEmpty && parent.isNotEmpty) result[branch] = parent;
    }
    return result;
  }

  /// From HEAD's history: the branch you were on the first time you
  /// switched to each branch ("checkout: moving from main to feature").
  Future<Map<String, String>> _parentsFromHeadHistory(String repo) async {
    final r = await _cli.run(
      ['reflog', 'show', '--format=%gs', '-n', '5000', 'HEAD'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final moving = RegExp(r'^checkout: moving from (.+) to (.+)$');
    final result = <String, String>{};
    // Newest first, so later (older) entries overwrite: the oldest wins.
    for (final line in _lines(r.stdout)) {
      final m = moving.firstMatch(line);
      if (m == null) continue;
      final from = m.group(1)!;
      final to = m.group(2)!;
      if (from == to || _sha.hasMatch(from)) continue;
      result[to] = from;
    }
    return result;
  }

  /// From the branch's own history: "branch: Created from main".
  Future<String?> _createdFrom(String repo, String branch) async {
    final r = await _cli.run(
      ['reflog', 'show', '--format=%gs', 'refs/heads/$branch'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final lines = _lines(r.stdout);
    if (lines.isEmpty) return null;
    final m = RegExp(r'^branch: Created from (.+)$').firstMatch(lines.last);
    if (m == null) return null;
    final from = _shortBranch(m.group(1)!.trim());
    return from == 'HEAD' || _sha.hasMatch(from) ? null : from;
  }

  static String _shortBranch(String ref) {
    var s = ref;
    for (final prefix in ['refs/heads/', 'refs/remotes/']) {
      if (s.startsWith(prefix)) s = s.substring(prefix.length);
    }
    if (s.startsWith('origin/')) s = s.substring('origin/'.length);
    return s;
  }

  /// `git rev-list --left-right --count a...b` → (behind, ahead) of b vs a.
  Future<(int, int)> _leftRight(String repo, String a, String b) async {
    final r = await _cli.run(
      ['rev-list', '--left-right', '--count', '$a...$b'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final parts = r.stdout.trim().split(RegExp(r'\s+'));
    if (!r.ok || parts.length < 2) return (0, 0);
    return (int.tryParse(parts[0]) ?? 0, int.tryParse(parts[1]) ?? 0);
  }

  Future<String?> _defaultBranch(
    String repo,
    Set<String> names,
    String? current,
  ) async {
    final r = await _cli.run(
      ['symbolic-ref', '--short', '-q', 'refs/remotes/origin/HEAD'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final remoteDefault = _shortBranch(r.stdout.trim());
    if (r.ok && names.contains(remoteDefault)) return remoteDefault;
    for (final candidate in ['main', 'master', 'trunk', 'develop']) {
      if (names.contains(candidate)) return candidate;
    }
    if (current != null && names.contains(current)) return current;
    return names.isEmpty ? null : names.first;
  }

  /// Which branch grew from which — the data behind the branch tree.
  ///
  /// Evidence, strongest first: what Gitty recorded when it created the
  /// branch; the branch's own "Created from" note; the first time HEAD moved
  /// to it; and finally the history itself (the branch it shares the most
  /// recent commit with).
  Future<BranchTree> branchTree(String repo) async {
    final refs = await _cli.run([
      'for-each-ref',
      '--format=%(refname)%09%(committerdate:unix)',
      'refs/heads',
      'refs/remotes',
    ], workingDirectory: repo);
    final local = <String, int>{};
    final remote = <String, (String, int)>{};
    for (final line in _lines(refs.stdout)) {
      final tab = line.indexOf('\t');
      if (tab < 0) continue;
      final ref = line.substring(0, tab);
      final date = int.tryParse(line.substring(tab + 1)) ?? 0;
      if (ref.startsWith('refs/heads/')) {
        local[ref.substring(11)] = date;
      } else if (ref.startsWith('refs/remotes/')) {
        final rest = ref.substring(13);
        final slash = rest.indexOf('/');
        if (slash < 0) continue;
        final remoteName = rest.substring(0, slash);
        final branch = rest.substring(slash + 1);
        if (branch == 'HEAD') continue;
        if (!remote.containsKey(branch) || remoteName == 'origin') {
          remote[branch] = (ref, date);
        }
      }
    }
    final names = {...local.keys, ...remote.keys};
    if (names.isEmpty) return const BranchTree(root: null, nodes: []);

    String refOf(String n) =>
        local.containsKey(n) ? 'refs/heads/$n' : remote[n]!.$1;
    int dateOf(String n) => local[n] ?? remote[n]?.$2 ?? 0;

    final current = await currentBranch(repo);
    final root = await _defaultBranch(repo, names, current);
    final recorded = await _recordedParents(repo);
    final fromHead = await _parentsFromHeadHistory(repo);

    final parents = <String, String>{};
    final guessed = <String>{};
    final counts = <String, (int, int)>{};

    for (final n in local.keys) {
      if (n == root) continue;
      final candidate =
          recorded[n] ?? await _createdFrom(repo, n) ?? fromHead[n];
      if (candidate != null && candidate != n && names.contains(candidate)) {
        parents[n] = candidate;
      }
    }

    // History-based guess for the rest: the branch it has the fewest
    // commits beyond is the one it most recently split from.
    for (final n in names) {
      if (n == root || parents.containsKey(n)) continue;
      final candidates = names.where((c) => c != n).toList()
        ..sort((a, b) {
          if (a == root) return -1;
          if (b == root) return 1;
          return dateOf(b).compareTo(dateOf(a));
        });
      String? best;
      var bestAhead = 1 << 30;
      for (final c in candidates.take(12)) {
        final lr = await _leftRight(repo, refOf(c), refOf(n));
        if (lr.$2 < bestAhead) {
          best = c;
          bestAhead = lr.$2;
          counts['$c>$n'] = lr;
        }
      }
      if (best != null) parents[n] = best;
      guessed.add(n);
    }

    // No loops: anything that would circle back hangs off the trunk.
    for (final n in parents.keys.toList()) {
      final seen = <String>{n};
      var p = parents[n];
      while (p != null) {
        if (!seen.add(p)) {
          if (root != null && n != root) parents[n] = root;
          break;
        }
        p = parents[p];
      }
    }
    if (root != null) parents.remove(root);

    final nodes = await Future.wait([
      for (final n in names)
        () async {
          final parent = n == root ? null : (parents[n] ?? root);
          var behind = 0;
          var ahead = 0;
          DateTime? forkedAt;
          if (parent != null) {
            final lr =
                counts['$parent>$n'] ??
                await _leftRight(repo, refOf(parent), refOf(n));
            behind = lr.$1;
            ahead = lr.$2;
            final mb = await _cli.run(
              ['merge-base', refOf(parent), refOf(n)],
              workingDirectory: repo,
              throwOnError: false,
            );
            if (mb.ok && mb.stdout.trim().isNotEmpty) {
              final when = await _cli.run(
                ['show', '-s', '--format=%ct', mb.stdout.trim()],
                workingDirectory: repo,
                throwOnError: false,
              );
              final seconds = int.tryParse(when.stdout.trim());
              if (seconds != null) {
                forkedAt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
              }
            }
          }
          final last = dateOf(n);
          return BranchNode(
            name: n,
            parent: parent,
            isRoot: n == root,
            isCurrent: n == current,
            isRemoteOnly: !local.containsKey(n),
            parentIsGuess: guessed.contains(n),
            ahead: ahead,
            behind: behind,
            forkedAt: forkedAt,
            lastCommitAt: last == 0
                ? null
                : DateTime.fromMillisecondsSinceEpoch(last * 1000),
          );
        }(),
    ]);
    return BranchTree(root: root, nodes: nodes);
  }

  /// Quick answer to "which branch did [branch] grow from?" (no history
  /// crawling — falls back to the trunk).
  Future<String?> branchParent(String repo, String branch) async {
    final recorded = await _recordedParents(repo);
    final parent =
        recorded[branch] ??
        await _createdFrom(repo, branch) ??
        (await _parentsFromHeadHistory(repo))[branch];
    if (parent != null && parent != branch) return parent;
    final refs = await _cli.run([
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/heads',
    ], workingDirectory: repo);
    final root = await _defaultBranch(repo, _lines(refs.stdout).toSet(), null);
    return root == branch ? null : root;
  }

  /// How the current branch compares with the branch it grew from — using
  /// the remote copy (`origin/main`) so teammates' pushes count.
  Future<ParentSync?> parentSync(String repo) async {
    final branch = await currentBranch(repo);
    if (branch == null) return null;
    final parent = await branchParent(repo, branch);
    if (parent == null) return null;
    String? parentRef;
    for (final candidate in ['origin/$parent', parent]) {
      final r = await _cli.run(
        ['rev-parse', '--verify', '--quiet', candidate],
        workingDirectory: repo,
        throwOnError: false,
      );
      if (r.ok) {
        parentRef = candidate;
        break;
      }
    }
    if (parentRef == null) return null;
    final count = await _cli.run(
      ['rev-list', '--count', 'HEAD..$parentRef'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final tip = await _cli.run(
      ['rev-parse', parentRef],
      workingDirectory: repo,
      throwOnError: false,
    );
    return ParentSync(
      branch: branch,
      parent: parent,
      parentRef: parentRef,
      behind: int.tryParse(count.stdout.trim()) ?? 0,
      parentTip: tip.ok ? tip.stdout.trim() : null,
    );
  }

  // ---------------------------------------------------------------------------
  // Remote changes
  // ---------------------------------------------------------------------------

  Future<Map<String, String>> _remoteTips(String repo) async {
    final r = await _cli.run([
      'for-each-ref',
      '--format=%(refname)%09%(objectname)',
      'refs/remotes',
    ], workingDirectory: repo);
    const prefix = 'refs/remotes/';
    final tips = <String, String>{};
    for (final line in _lines(r.stdout)) {
      final tab = line.indexOf('\t');
      if (tab < 0 || !line.startsWith(prefix)) continue;
      final ref = line.substring(prefix.length, tab); // e.g. origin/main
      if (!ref.contains('/') || ref.endsWith('/HEAD')) continue;
      tips[ref] = line.substring(tab + 1);
    }
    return tips;
  }

  /// Fetches, then reports which remote branches moved and who pushed.
  Future<List<RemoteUpdate>> fetchWithUpdates(String repo) async {
    final before = await _remoteTips(repo);
    await fetch(repo);
    final after = await _remoteTips(repo);
    final updates = <RemoteUpdate>[];
    for (final MapEntry(key: ref, value: tip) in after.entries) {
      final old = before[ref];
      if (old == tip) continue;
      final branch = ref.substring(ref.indexOf('/') + 1);
      final log = await _cli.run(
        [
          'log',
          '--format=%an',
          '-n',
          old == null ? '1' : '200',
          old == null ? tip : '$old..$tip',
        ],
        workingDirectory: repo,
        throwOnError: false,
      );
      final authors = <String>[];
      for (final a in _lines(log.stdout)) {
        if (!authors.contains(a)) authors.add(a);
      }
      var count = 0;
      if (old != null) {
        final c = await _cli.run(
          ['rev-list', '--count', '$old..$tip'],
          workingDirectory: repo,
          throwOnError: false,
        );
        count = int.tryParse(c.stdout.trim()) ?? 0;
      }
      updates.add(
        RemoteUpdate(
          remoteRef: ref,
          branch: branch,
          newCommits: count,
          authors: authors,
          isNewBranch: old == null,
          rewritten: old != null && count == 0,
          tip: tip,
        ),
      );
    }
    return updates;
  }


  /// Switches to [name]. For remote-only branches git creates a local tracking
  /// branch automatically.
  Future<void> switchBranch(String repo, String name) =>
      _cli.run(['switch', name], workingDirectory: repo);

  // ---------------------------------------------------------------------------
  // Cloning
  // ---------------------------------------------------------------------------

  /// Clones [url] into [parentDirectory] and returns the new repository path.
  Future<String> clone(
    String url,
    String parentDirectory, {
    String? folderName,
  }) async {
    final name = folderName ?? repoNameFromUrl(url);
    final target = p.join(parentDirectory, name);
    if (Directory(target).existsSync()) {
      throw GittyException(
        'A folder named "$name" already exists there.',
        hint: 'Pick another location or remove the existing folder.',
        details: target,
      );
    }
    await _network(
      ['clone', '--', url, name],
      workingDirectory: parentDirectory,
      timeout: const Duration(minutes: 20),
    );
    return target;
  }

  // ---------------------------------------------------------------------------
  // Changes put aside (stash)
  // ---------------------------------------------------------------------------

  /// Everything on the shelf, newest first.
  Future<List<StashEntry>> stashes(String repo) async {
    final r = await _cli.run(
      ['stash', 'list', '--format=%H%x1f%ct%x1f%gs'],
      workingDirectory: repo,
      throwOnError: false,
    );
    return r.ok ? parseStashList(r.stdout) : const [];
  }

  /// Files in one shelf entry (including new files, on Git 2.32+).
  Future<List<NameStatus>> stashFiles(String repo, String hash) async {
    var r = await _cli.run(
      ['stash', 'show', '--include-untracked', '--name-status', hash],
      workingDirectory: repo,
      throwOnError: false,
    );
    if (!r.ok) {
      r = await _cli.run([
        'stash',
        'show',
        '--name-status',
        hash,
      ], workingDirectory: repo);
    }
    return parseNameStatus(r.stdout);
  }

  /// What a shelf entry changes, as a (shortened) diff.
  Future<String> stashDiff(String repo, String hash, {int maxChars = 12000}) async {
    var r = await _cli.run(
      ['stash', 'show', '-p', '--no-color', '--include-untracked', hash],
      workingDirectory: repo,
      throwOnError: false,
    );
    if (!r.ok) {
      r = await _cli.run([
        'stash',
        'show',
        '-p',
        '--no-color',
        hash,
      ], workingDirectory: repo);
    }
    return compactDiff(r.stdout, maxChars: maxChars, perFileChars: 2500);
  }

  /// All uncommitted changes (staged or not) as a shortened diff, for AI
  /// summaries. New files are listed by the caller (they have no diff yet).
  Future<String> workingDiff(String repo, {int maxChars = 12000}) async {
    final hasHead = (await _cli.run(
      ['rev-parse', '--verify', '-q', 'HEAD'],
      workingDirectory: repo,
      throwOnError: false,
    )).ok;
    final r = await _cli.run([
      'diff',
      if (hasHead) 'HEAD' else '--cached',
      '--no-color',
      '--no-ext-diff',
      '--unified=2',
      '--',
      '.',
      for (final glob in noisyDiffGlobs) ':(exclude,glob)$glob',
    ], workingDirectory: repo);
    return compactDiff(r.stdout, maxChars: maxChars, perFileChars: 2500);
  }

  /// Puts uncommitted changes (including new files) on the shelf under
  /// [name]. Returns the entry's id.
  Future<String> stashPush(String repo, String name, {List<String>? paths}) async {
    final before = await _stashTip(repo);
    await _cli.run([
      'stash',
      'push',
      '--include-untracked',
      '-m',
      name,
      if (paths != null) ...['--', ...paths],
    ], workingDirectory: repo);
    final after = await _stashTip(repo);
    if (after == null || after == before) {
      throw const GittyException('There was nothing to put aside.');
    }
    return after;
  }

  Future<int> _stashIndex(String repo, String hash) async {
    final list = await _cli.run([
      'stash',
      'list',
      '--format=%H',
    ], workingDirectory: repo);
    final index = _lines(list.stdout).indexOf(hash);
    if (index < 0) {
      throw const GittyException(
        'Those changes aren’t on the shelf anymore.',
        hint: 'They may have been brought back or thrown away already.',
      );
    }
    return index;
  }

  /// Brings shelf changes back into your files. With [keep], a copy stays
  /// on the shelf.
  Future<void> stashApply(String repo, String hash, {bool keep = false}) async {
    final ref = 'stash@{${await _stashIndex(repo, hash)}}';
    final cmd = keep ? 'apply' : 'pop';
    final exact = await _cli.run(
      ['stash', cmd, '--index', ref],
      workingDirectory: repo,
      throwOnError: false,
    );
    if (exact.ok) return;
    final said = '${exact.stdout}\n${exact.stderr}'.toLowerCase();
    if (said.contains('conflict')) {
      throw GittyException(
        'Some of these changes clash with your current files.',
        hint:
            'Use “Resolve conflicts” in the changes list to pick what to '
            'keep. The changes also stay on the shelf until you’re done.',
        details: '${exact.stdout}\n${exact.stderr}'.trim(),
      );
    }
    // Staging couldn't be restored exactly — bring the files back anyway.
    await _cli.run(['stash', cmd, ref], workingDirectory: repo);
  }

  /// Gives a shelf entry a new name. (Git can't rename, so it's stored
  /// again under the new name and the old entry is removed.)
  Future<void> stashRename(String repo, String hash, String name) async {
    await _stashIndex(repo, hash); // still there?
    await _cli.run([
      'stash',
      'store',
      '-m',
      name,
      hash,
    ], workingDirectory: repo);
    final list = await _cli.run([
      'stash',
      'list',
      '--format=%H',
    ], workingDirectory: repo);
    final hashes = _lines(list.stdout);
    final first = hashes.indexOf(hash);
    final second = first < 0 ? -1 : hashes.indexOf(hash, first + 1);
    if (second >= 0) {
      await _cli.run([
        'stash',
        'drop',
        'stash@{$second}',
      ], workingDirectory: repo);
    }
  }

  /// Throws a shelf entry away.
  Future<void> stashDrop(String repo, String hash) async {
    final ref = 'stash@{${await _stashIndex(repo, hash)}}';
    await _cli.run(['stash', 'drop', ref], workingDirectory: repo);
  }

  // ---------------------------------------------------------------------------
  // Undo
  // ---------------------------------------------------------------------------

  /// Keeps a named pointer to where HEAD is now, so nothing an undo moves
  /// away from is ever lost (see `refs/gitty/before-undo/`).
  Future<void> _keepSafetyPoint(String repo) => _cli.run([
    'update-ref',
    'refs/gitty/before-undo/${DateTime.now().millisecondsSinceEpoch}',
    'HEAD',
  ], workingDirectory: repo, throwOnError: false);

  /// Moves the current branch back to [hash]. [keepChangesStaged]: the
  /// undone commits' changes stay in your files, ready to commit again
  /// (`reset --soft`); otherwise your uncommitted edits are kept and Git
  /// stops if they'd be overwritten (`reset --keep`).
  Future<void> moveBranchTo(
    String repo,
    String hash, {
    required bool keepChangesStaged,
  }) async {
    await _keepSafetyPoint(repo);
    await _cli.run([
      'reset',
      keepChangesStaged ? '--soft' : '--keep',
      hash,
    ], workingDirectory: repo);
  }

  /// Makes a new commit that undoes [hash] — safe for commits already online.
  Future<void> revertCommit(String repo, String hash) =>
      _cli.run(['revert', '--no-edit', hash], workingDirectory: repo);

  /// True when [hash] is already on some online branch.
  Future<bool> isOnline(String repo, String hash) async {
    final r = await _cli.run(
      ['branch', '-r', '--contains', hash],
      workingDirectory: repo,
      throwOnError: false,
    );
    return r.ok && r.stdout.trim().isNotEmpty;
  }

  /// Local branch names.
  Future<Set<String>> localBranches(String repo) async {
    final r = await _cli.run([
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/heads',
    ], workingDirectory: repo);
    return _lines(r.stdout).toSet();
  }

  /// Deletes a local branch, but only when its work is safe elsewhere.
  Future<void> deleteBranch(String repo, String name) async {
    final r = await _cli.run(
      ['branch', '-d', name],
      workingDirectory: repo,
      throwOnError: false,
    );
    if (r.ok) return;
    if ('${r.stderr}${r.stdout}'.contains('not fully merged')) {
      throw GittyException(
        '“$name” has commits that aren’t anywhere else yet.',
        hint: 'Gitty won’t delete it so nothing is lost. Merge or push it first.',
        details: r.stderr.trim(),
      );
    }
    throw mapGitError(['branch', '-d', name], r);
  }

  /// Brings back a deleted branch at [hash].
  Future<void> restoreBranch(String repo, String name, String hash) =>
      _cli.run(['branch', name, hash], workingDirectory: repo);

  Future<void> renameBranch(String repo, String from, String to) =>
      _cli.run(['branch', '-m', from, to], workingDirectory: repo);

  /// Every branch, local and online-only, most recently worked on first —
  /// one quick git call (no history walking), for the Switch branch list.
  Future<List<BranchSummary>> branchSummaries(String repo) async {
    final r = await _cli.run([
      'for-each-ref',
      '--sort=-committerdate',
      '--format=%(refname)%09%(committerdate:unix)%09%(upstream:short)%09%(contents:subject)',
      'refs/heads',
      'refs/remotes',
    ], workingDirectory: repo);
    return parseBranchSummaries(r.stdout);
  }

  /// Renames [from] to [to] on this computer. Branches that grew from it
  /// keep pointing at it. With [online], it's renamed on the remote it's
  /// linked to as well (the new name is pushed and linked, the old one
  /// removed) — note that an open pull request for the old name closes.
  Future<void> renameBranchFully(
    String repo,
    String from,
    String to, {
    bool online = false,
  }) async {
    String? remote;
    String? remoteName;
    if (online) {
      final up = await _cli.run(
        ['rev-parse', '--abbrev-ref', '$from@{upstream}'],
        workingDirectory: repo,
        throwOnError: false,
      );
      final u = up.stdout.trim();
      final slash = u.indexOf('/');
      if (up.ok && slash > 0) {
        remote = u.substring(0, slash);
        remoteName = u.substring(slash + 1);
      }
    }

    await _cli.run(['branch', '-m', from, to], workingDirectory: repo);

    // Branches Gitty recorded as "grew from <from>" now grew from <to>.
    final kids = await _cli.run(
      ['config', '--get-regexp', r'^branch\..*\.gittyparent$'],
      workingDirectory: repo,
      throwOnError: false,
    );
    for (final line in _lines(kids.stdout)) {
      final space = line.indexOf(' ');
      if (space < 0 || line.substring(space + 1).trim() != from) continue;
      final key = line.substring(0, space);
      final branch = key.substring('branch.'.length, key.lastIndexOf('.'));
      await _cli.run(
        ['config', '--local', 'branch.$branch.$_parentKey', to],
        workingDirectory: repo,
        throwOnError: false,
      );
    }

    if (remote == null || remoteName == null) return;
    await _network(['push', '-u', remote, to], workingDirectory: repo);
    try {
      await _network(
        ['push', remote, '--delete', remoteName],
        workingDirectory: repo,
      );
    } on GittyException catch (e) {
      throw GittyException(
        'Renamed — but the old name “$remoteName” is still on $remote.',
        hint:
            'It may be protected, or you may not be allowed to delete '
            'branches there. Remove it on the website if you like.',
        details: e.details ?? e.message,
      );
    }
  }

  /// Removes [branch] from [remote] (e.g. to undo publishing it).
  Future<void> deleteRemoteBranch(String repo, String remote, String branch) =>
      _network(['push', remote, '--delete', branch], workingDirectory: repo);

  // ---------------------------------------------------------------------------
  // Conflicts
  // ---------------------------------------------------------------------------

  /// What's clashing right now, and during which operation.
  Future<ConflictState> conflictState(String repo) async {
    final dirR = await _cli.run([
      'rev-parse',
      '--absolute-git-dir',
    ], workingDirectory: repo);
    final gitDir = dirR.stdout.trim();
    bool has(String name) =>
        FileSystemEntity.typeSync(p.join(gitDir, name)) !=
        FileSystemEntityType.notFound;

    final unmerged = await _cli.run([
      'ls-files',
      '-u',
    ], workingDirectory: repo);
    final files = parseUnmerged(unmerged.stdout);
    final current = await currentBranch(repo);

    Future<String?> nameOf(String rev) async {
      final r = await _cli.run(
        ['name-rev', '--name-only', '--exclude=refs/tags/*', rev],
        workingDirectory: repo,
        throwOnError: false,
      );
      final name = r.stdout.trim();
      if (!r.ok || name.isEmpty || name == 'undefined') return null;
      return name.replaceFirst('remotes/', '');
    }

    String? readText(String name) {
      try {
        return File(p.join(gitDir, name)).readAsStringSync().trim();
      } catch (_) {
        return null;
      }
    }

    if (has('rebase-merge') || has('rebase-apply')) {
      final dir = has('rebase-merge') ? 'rebase-merge' : 'rebase-apply';
      final onto = readText(p.join(dir, 'onto'));
      final head = readText(p.join(dir, 'head-name'));
      return ConflictState(
        operation: ConflictOperation.rebase,
        files: files,
        incoming: onto == null ? null : await nameOf(onto),
        currentBranch: head?.replaceFirst('refs/heads/', '') ?? current,
      );
    }
    if (has('MERGE_HEAD')) {
      return ConflictState(
        operation: ConflictOperation.merge,
        files: files,
        incoming: await nameOf('MERGE_HEAD'),
        currentBranch: current,
      );
    }
    if (has('CHERRY_PICK_HEAD')) {
      return ConflictState(
        operation: ConflictOperation.cherryPick,
        files: files,
        currentBranch: current,
      );
    }
    if (has('REVERT_HEAD')) {
      return ConflictState(
        operation: ConflictOperation.revert,
        files: files,
        currentBranch: current,
      );
    }
    return ConflictState(
      operation: ConflictOperation.other,
      files: files,
      currentBranch: current,
    );
  }

  /// Saves a resolved file and marks it as sorted out.
  Future<void> saveResolved(String repo, String path, String content) async {
    await File(p.join(repo, path)).writeAsString(content, flush: true);
    await _cli.run(['add', '--', path], workingDirectory: repo);
  }

  /// Resolves a whole file by taking one side. [ours] = the HEAD side.
  Future<void> takeSide(String repo, String path, {required bool ours}) async {
    await _cli.run([
      'checkout',
      ours ? '--ours' : '--theirs',
      '--',
      path,
    ], workingDirectory: repo);
    await _cli.run(['add', '--', path], workingDirectory: repo);
  }

  /// For "one side deleted it" clashes: keep the file or remove it.
  Future<void> keepOrDelete(String repo, String path, {required bool keep}) =>
      _cli.run(
        keep ? ['add', '--', path] : ['rm', '-q', '--', path],
        workingDirectory: repo,
      );

  /// Finishes the merge/rebase/… once every clash is resolved.
  Future<void> continueOperation(String repo, ConflictOperation op) async {
    const quiet = {'GIT_EDITOR': 'true'};
    final args = switch (op) {
      ConflictOperation.merge => ['commit', '--no-edit'],
      ConflictOperation.rebase => ['rebase', '--continue'],
      ConflictOperation.cherryPick => ['cherry-pick', '--continue'],
      ConflictOperation.revert => ['revert', '--continue'],
      ConflictOperation.other => <String>[],
    };
    if (args.isEmpty) return;
    await _cli.run(args, workingDirectory: repo, environment: quiet);
  }

  /// Cancels the merge/rebase/… and goes back to how things were.
  Future<void> abortOperation(String repo, ConflictOperation op) async {
    final args = switch (op) {
      ConflictOperation.merge => ['merge', '--abort'],
      ConflictOperation.rebase => ['rebase', '--abort'],
      ConflictOperation.cherryPick => ['cherry-pick', '--abort'],
      ConflictOperation.revert => ['revert', '--abort'],
      ConflictOperation.other => <String>[],
    };
    if (args.isEmpty) return;
    await _cli.run(args, workingDirectory: repo);
  }

  // ---------------------------------------------------------------------------
  // Pull requests (the Git side)
  // ---------------------------------------------------------------------------

  /// The online default branch (e.g. "main"), from `origin/HEAD`.
  Future<String?> remoteDefaultBranch(String repo, {String remote = 'origin'}) async {
    final r = await _cli.run(
      ['symbolic-ref', '--short', '-q', 'refs/remotes/$remote/HEAD'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final ref = r.stdout.trim();
    if (!r.ok || !ref.startsWith('$remote/')) return null;
    return ref.substring(remote.length + 1);
  }

  /// Branch names that exist on [remote] (without the "origin/" prefix).
  Future<List<String>> remoteBranchNames(String repo, {String remote = 'origin'}) async {
    final r = await _cli.run([
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/remotes/$remote',
    ], workingDirectory: repo);
    return [
      for (final ref in _lines(r.stdout))
        if (ref.startsWith('$remote/') && ref != '$remote/HEAD')
          ref.substring(remote.length + 1),
    ]..sort();
  }

  /// The branch [branch] grew from, as recorded by Gitty (or null).
  Future<String?> recordedParent(String repo, String branch) async {
    final r = await _cli.run(
      ['config', '--get', 'branch.$branch.$_parentKey'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final v = r.stdout.trim();
    return r.ok && v.isNotEmpty ? v : null;
  }

  /// Commit messages and a file summary between [base] and HEAD, for
  /// writing a pull request description.
  Future<(List<String> subjects, String log, String stat)> changesSince(
    String repo,
    String base,
  ) async {
    final subjects = await _cli.run([
      'log',
      '--format=%s',
      '$base..HEAD',
    ], workingDirectory: repo);
    final log = await _cli.run([
      'log',
      '--format=- %s%n%b',
      '-n',
      '50',
      '$base..HEAD',
    ], workingDirectory: repo);
    final stat = await _cli.run([
      'diff',
      '--stat',
      '--no-color',
      '$base...HEAD',
    ], workingDirectory: repo);
    final text = log.stdout.length > 8000
        ? '${log.stdout.substring(0, 8000)}\n…'
        : log.stdout;
    return (_lines(subjects.stdout), text.trim(), stat.stdout.trim());
  }

  // ---------------------------------------------------------------------------
  // Reverting (discarding changes) — with an undo
  // ---------------------------------------------------------------------------

  Future<String?> _stashTip(String repo) async {
    final r = await _cli.run(
      ['rev-parse', '-q', '--verify', 'refs/stash'],
      workingDirectory: repo,
      throwOnError: false,
    );
    final sha = r.stdout.trim();
    return r.ok && sha.isNotEmpty ? sha : null;
  }

  /// Puts [paths] (or every change, when null) back to the last commit.
  /// New files are removed.
  ///
  /// First tries to keep a backup with `git stash push --include-untracked`,
  /// so it can be undone with [undoRevert]; returns that backup's id. When a
  /// backup isn't possible (no commits yet, or conflicts), changes are
  /// discarded directly and null is returned.
  Future<String?> revert(String repo, {List<String>? paths}) async {
    final what = paths == null
        ? 'all changes'
        : paths.length == 1
        ? paths.first
        : '${paths.length} files';
    final when = DateTime.now().toIso8601String().substring(0, 16);
    final before = await _stashTip(repo);
    final r = await _cli.run(
      [
        'stash',
        'push',
        '--include-untracked',
        '-m',
        'Gitty backup before reverting $what ($when)',
        if (paths != null) ...['--', ...paths],
      ],
      workingDirectory: repo,
      throwOnError: false,
    );
    final after = await _stashTip(repo);
    if (r.ok && after != null && after != before) return after;

    await _discardDirectly(repo, paths);
    return null;
  }

  Future<void> _discardDirectly(String repo, List<String>? paths) async {
    final s = await status(repo);
    final targets = paths?.toSet();
    bool wanted(FileChange c) =>
        targets == null ||
        targets.contains(c.path) ||
        (c.originalPath != null && targets.contains(c.originalPath));
    final chosen = s.changes.where(wanted).toList();
    final untracked = [
      for (final c in chosen)
        if (c.isUntracked) c.path,
    ];
    final tracked = <String>{
      for (final c in chosen)
        if (!c.isUntracked) ...[
          c.path,
          if (c.originalPath != null) c.originalPath!,
        ],
    }.toList();

    if (tracked.isNotEmpty) {
      if (s.hasCommits) {
        await _cli.run([
          'restore',
          '--source=HEAD',
          '--staged',
          '--worktree',
          '--',
          ...tracked,
        ], workingDirectory: repo);
      } else {
        // No commits yet: "the last commit" is nothing, so staged files go.
        await _cli.run([
          'rm',
          '--cached',
          '-r',
          '-f',
          '-q',
          '--',
          ...tracked,
        ], workingDirectory: repo);
        untracked.addAll(tracked);
      }
    }
    if (untracked.isNotEmpty) {
      await _cli.run([
        'clean',
        '-f',
        '-d',
        '-q',
        '--',
        ...untracked,
      ], workingDirectory: repo);
    }
  }

  /// Brings back what [revert] put aside (by its backup id).
  Future<void> undoRevert(String repo, String backup) async {
    final list = await _cli.run([
      'stash',
      'list',
      '--format=%H',
    ], workingDirectory: repo);
    final index = _lines(list.stdout).indexOf(backup);
    if (index < 0) {
      throw const GittyException(
        'That backup isn’t there anymore.',
        hint: 'It may have been restored or removed already.',
      );
    }
    final ref = 'stash@{$index}';
    final withIndex = await _cli.run(
      ['stash', 'pop', '--index', ref],
      workingDirectory: repo,
      throwOnError: false,
    );
    if (withIndex.ok) return;
    // Staging couldn't be restored exactly — bring the files back anyway.
    await _cli.run(['stash', 'pop', ref], workingDirectory: repo);
  }

  // ---------------------------------------------------------------------------
  // Lock files (.git/index.lock and friends)
  // ---------------------------------------------------------------------------

  /// Is [lockPath] still in use, or a leftover from a git command that
  /// stopped halfway? Checks (macOS/Linux) whether any process has the file
  /// open or any git process is running in [repo].
  Future<GitLockInfo> inspectLock(String repo, String lockPath) async {
    final file = File(lockPath);
    if (!await file.exists()) {
      return GitLockInfo(path: lockPath, exists: false);
    }
    DateTime? modified;
    try {
      modified = await file.lastModified();
    } catch (_) {}

    bool? inUse;
    if (!Platform.isWindows) {
      try {
        final holders = await Process.run('lsof', ['-t', lockPath]);
        var busy = holders.stdout.toString().trim().isNotEmpty;
        if (!busy) busy = await _gitRunningIn(repo);
        inUse = busy;
      } catch (_) {
        inUse = null; // lsof/pgrep unavailable — can't tell.
      }
    }
    return GitLockInfo(
      path: lockPath,
      exists: true,
      modified: modified,
      inUse: inUse,
    );
  }

  /// True if a `git` process has its working directory inside [repo]
  /// (e.g. `git commit` waiting for an editor, or an IDE's git call).
  Future<bool> _gitRunningIn(String repo) async {
    final pids = await Process.run('pgrep', ['-x', 'git']);
    final list = pids.stdout
        .toString()
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (list.isEmpty) return false;
    final cwd = await Process.run('lsof', [
      '-a',
      '-d',
      'cwd',
      '-p',
      list.join(','),
      '-Fn',
    ]);
    final root = p.normalize(repo);
    return cwd.stdout
        .toString()
        .split('\n')
        .where((l) => l.startsWith('n'))
        .map((l) => p.normalize(l.substring(1)))
        .any((dir) => dir == root || p.isWithin(root, dir));
  }

  /// Deletes a leftover lock. Refuses anything that isn't a `*.lock` file
  /// inside a `.git` folder.
  Future<void> removeLock(String lockPath) async {
    final normalized = p.normalize(lockPath);
    final parts = p.split(normalized);
    if (!normalized.endsWith('.lock') || !parts.contains('.git')) {
      throw GittyException(
        'That doesn’t look like a Git lock file, so Gitty left it alone.',
        details: lockPath,
      );
    }
    final file = File(normalized);
    if (await file.exists()) await file.delete();
  }

  // ---------------------------------------------------------------------------
  // Author identity (user.name / user.email)
  // ---------------------------------------------------------------------------

  /// The name and email Git will use for commits in [repo], with the scope
  /// each one comes from.
  Future<GitIdentity> identity(String repo) async {
    Future<(String?, String?)> read(String key) async {
      final r = await _cli.run(
        ['config', '--show-scope', '--get', key],
        workingDirectory: repo,
        throwOnError: false,
      );
      if (r.ok) {
        final line = r.stdout.trim();
        final tab = line.indexOf('\t');
        if (tab > 0) return (line.substring(tab + 1), line.substring(0, tab));
        return (line.isEmpty ? null : line, null);
      }
      // Git older than 2.26 has no --show-scope.
      final plain = await _cli.run(
        ['config', '--get', key],
        workingDirectory: repo,
        throwOnError: false,
      );
      final value = plain.stdout.trim();
      if (!plain.ok || value.isEmpty) return (null, null);
      final local = await _cli.run(
        ['config', '--local', '--get', key],
        workingDirectory: repo,
        throwOnError: false,
      );
      return (value, local.ok ? 'local' : 'global');
    }

    final results = await Future.wait([read('user.name'), read('user.email')]);
    return GitIdentity(
      name: results[0].$1,
      nameScope: results[0].$2,
      email: results[1].$1,
      emailScope: results[1].$2,
    );
  }

  /// Saves the author for [repo] only — written to the repository's own
  /// `.git/config` with `--local`. Global settings are never touched.
  Future<void> setLocalIdentity(String repo, String name, String email) async {
    final n = name.trim();
    final m = email.trim();
    final problem = validateIdentity(n, m);
    if (problem != null) throw GittyException(problem);
    await _cli.run(['config', '--local', 'user.name', n], workingDirectory: repo);
    await _cli.run([
      'config',
      '--local',
      'user.email',
      m,
    ], workingDirectory: repo);
  }

  /// Null when [name]/[email] look fine, otherwise a friendly reason.
  static String? validateIdentity(String name, String email) {
    if (name.trim().isEmpty) return 'Please enter your name.';
    if (name.contains(RegExp(r'[<>\n]'))) {
      return 'Names can’t contain < > or line breaks.';
    }
    if (!RegExp(r'^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$').hasMatch(email.trim())) {
      return 'That email doesn’t look right (e.g. you@example.com).';
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // .gitignore
  // ---------------------------------------------------------------------------

  File _gitignoreFile(String repo) => File(p.join(repo, '.gitignore'));

  /// Contents of the repository's top-level .gitignore, or null if missing.
  Future<String?> readGitignore(String repo) async {
    final file = _gitignoreFile(repo);
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return ''; // Exists but unreadable — treat as present.
    }
  }

  /// Names directly inside [repo] (used to guess the project type).
  Future<List<String>> topLevelNames(String repo) async {
    final names = <String>[];
    try {
      await for (final entity in Directory(repo).list()) {
        names.add(p.basename(entity.path));
      }
    } catch (_) {
      // Unreadable — no suggestions.
    }
    return names;
  }

  /// Shows what [rules] would hide, without writing anything.
  Future<GitignorePreview> previewGitignore(String repo, String rules) async {
    final tempDir = await Directory.systemTemp.createTemp('gitty-ignore-');
    try {
      final rulesFile = File(p.join(tempDir.path, 'rules'));
      await rulesFile.writeAsString(rules);
      const listIgnored = ['ls-files', '--others', '--ignored', '--directory'];
      final results = await Future.wait([
        _cli.run([...listIgnored, '--exclude-standard'], workingDirectory: repo),
        _cli.run([
          ...listIgnored,
          '--exclude-standard',
          '--exclude-from=${rulesFile.path}',
        ], workingDirectory: repo),
        _cli.run([
          'ls-files',
          '--cached',
          '--ignored',
          '--exclude-from=${rulesFile.path}',
        ], workingDirectory: repo),
      ]);
      final before = _lines(results[0].stdout).toSet();
      final after = _lines(results[1].stdout);
      return GitignorePreview(
        newlyHidden: [
          for (final path in after)
            if (!before.contains(path)) path,
        ],
        stillTracked: _lines(results[2].stdout),
      );
    } finally {
      unawaited(tempDir.delete(recursive: true).catchError((_) => tempDir));
    }
  }

  /// Creates .gitignore with [content], or appends it when [append] is true.
  Future<void> writeGitignore(
    String repo,
    String content, {
    bool append = false,
  }) async {
    final file = _gitignoreFile(repo);
    try {
      if (append && await file.exists()) {
        final current = await file.readAsString();
        final glue = current.isEmpty || current.endsWith('\n') ? '' : '\n';
        await file.writeAsString('$glue$content', mode: FileMode.append);
      } else {
        await file.writeAsString(content);
      }
    } on FileSystemException catch (e) {
      throw GittyException(
        "Gitty couldn't save the .gitignore file.",
        hint: 'Check that the folder is writable, then try again.',
        details: '${e.message}: ${e.path ?? file.path}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Network + GitHub credentials
  // ---------------------------------------------------------------------------

  /// Runs a command that talks to a remote.
  ///
  /// The user's own git setup (credential helpers, SSH keys) always goes
  /// first. Only if GitHub turns the request away for missing/invalid
  /// credentials — and a GitHub account is connected in Gitty — is it
  /// retried once with that account's token.
  Future<GitCommandResult> _network(
    List<String> args, {
    required String workingDirectory,
    Duration timeout = GitCli.networkTimeout,
  }) async {
    final first = await _cli.run(
      args,
      workingDirectory: workingDirectory,
      throwOnError: false,
      timeout: timeout,
    );
    if (first.ok) return first;

    final reader = _githubToken;
    if (reader != null && _isGitHubAuthFailure(first)) {
      final token = await reader();
      if (token != null && token.isNotEmpty) {
        final second = await _cli.run(
          args,
          workingDirectory: workingDirectory,
          throwOnError: false,
          timeout: timeout,
          environment: githubAuthEnvironment(token),
        );
        if (second.ok) return second;
        throw _withNote(
          mapGitError(args, second),
          "Gitty tried your computer's saved GitHub sign-in first, then the "
          'GitHub account connected in Gitty. Neither is allowed to do this.',
        );
      }
      throw _withNote(
        mapGitError(args, first),
        "Gitty used your computer's saved GitHub sign-in. No GitHub account "
        'is connected in Gitty (Settings → GitHub).',
      );
    }
    throw mapGitError(args, first);
  }

  /// Adds which sign-ins were tried to an error's details (plain errors
  /// only; special ones like "repository locked" pass through).
  static GittyException _withNote(GittyException e, String note) =>
      e.runtimeType == GittyException
      ? GittyException(
          e.message,
          hint: e.hint,
          details: e.details == null ? note : '${e.details}\n\n$note',
        )
      : e;

  static bool _isGitHubAuthFailure(GitCommandResult r) {
    final text = '${r.stderr}\n${r.stdout}'.toLowerCase();
    if (!text.contains('github.com')) return false;
    return text.contains('terminal prompts disabled') ||
        text.contains('could not read username') ||
        text.contains('could not read password') ||
        text.contains('authentication failed') ||
        text.contains('invalid username or password') ||
        text.contains('repository not found') ||
        text.contains('permission to') ||
        text.contains('403');
  }

  /// Environment that makes git send the token to github.com over HTTPS.
  ///
  /// Uses `GIT_CONFIG_*` (git 2.31+) so the token never appears in the
  /// process list or in any config file, and the header is scoped to
  /// https://github.com/ only.
  static Map<String, String> githubAuthEnvironment(String token) {
    final basic = base64Encode(utf8.encode('x-access-token:$token'));
    return {
      'GIT_CONFIG_COUNT': '1',
      'GIT_CONFIG_KEY_0': 'http.https://github.com/.extraheader',
      'GIT_CONFIG_VALUE_0': 'AUTHORIZATION: basic $basic',
    };
  }

  static String repoNameFromUrl(String url) {
    var s = url.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('.git')) s = s.substring(0, s.length - 4);
    final cut = s.lastIndexOf(RegExp(r'[/:]'));
    final name = cut >= 0 ? s.substring(cut + 1) : s;
    return name.isEmpty ? 'repository' : name;
  }

  static List<String> _lines(String s) =>
      s.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
}

/// Status output size (characters) above which parsing moves to a
/// background isolate.
const _bigStatusOutput = 64 * 1024;

// Top-level so the isolate closure captures nothing but [output].
Future<RepoStatus> _parseStatusInBackground(String output) =>
    Isolate.run(() => parsePorcelainV2(output));

/// Reads reflog files and builds the activity list (runs in an isolate).
/// Only the most recent part of long logs is read.
List<ActivityEvent> _readActivity(
  String gitDir,
  String commonDir,
  String? currentBranch,
  int limit,
) {
  List<String> tail(File f) {
    try {
      final lines = f.readAsLinesSync();
      return lines.length > 3000 ? lines.sublist(lines.length - 3000) : lines;
    } catch (_) {
      return const [];
    }
  }

  Map<String, List<String>> logsUnder(String dir) {
    final root = Directory(dir);
    if (!root.existsSync()) return const {};
    final out = <String, List<String>>{};
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p
          .relative(entity.path, from: dir)
          .replaceAll(r'\', '/');
      out[name] = tail(entity);
    }
    return out;
  }

  return parseActivity(
    headLog: tail(File(p.join(gitDir, 'logs', 'HEAD'))),
    branchLogs: logsUnder(p.join(commonDir, 'logs', 'refs', 'heads')),
    remoteLogs: logsUnder(p.join(commonDir, 'logs', 'refs', 'remotes')),
    currentBranch: currentBranch,
    limit: limit,
  );
}

// Top-level so the isolate closures capture nothing but their arguments.
Future<List<ActivityEvent>> _activityInBackground(
  String gitDir,
  String commonDir,
  String? currentBranch,
  int limit,
) => Isolate.run(() => _readActivity(gitDir, commonDir, currentBranch, limit));

Future<List<HistoryCommit>> _commitLogInBackground(String output) =>
    Isolate.run(() => parseCommitLog(output));
