import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/core/widgets/status_pill.dart';
import 'package:gitty/features/dashboard/repo_widgets.dart';
import 'package:gitty/services/git/git_models.dart';
import 'package:gitty/services/storage/repo_repository.dart';

void main() {
  group('remote host detection', () {
    test('GitHub https', () {
      final h = RemoteHost.parse('https://github.com/octocat/Hello-World.git');
      expect(h.kind, RemoteHostKind.github);
      expect(h.webUrl.toString(), 'https://github.com/octocat/Hello-World');
    });
    test('GitLab scp-style ssh', () {
      final h = RemoteHost.parse('git@gitlab.com:team/app.git');
      expect(h.kind, RemoteHostKind.gitlab);
      expect(h.label, 'GitLab');
      expect(h.webUrl.toString(), 'https://gitlab.com/team/app');
    });
    test('self-hosted GitLab over ssh:// with port', () {
      final h = RemoteHost.parse('ssh://git@gitlab.acme.io:2222/web/site.git');
      expect(h.kind, RemoteHostKind.gitlab);
      expect(h.host, 'gitlab.acme.io');
    });
    test('Bitbucket and Azure DevOps', () {
      expect(
        RemoteHost.parse('https://me@bitbucket.org/team/repo.git').kind,
        RemoteHostKind.bitbucket,
      );
      final azure = RemoteHost.parse('git@ssh.dev.azure.com:v3/org/proj/repo');
      expect(azure.kind, RemoteHostKind.azure);
      expect(azure.webUrl.toString(), 'https://dev.azure.com/org/proj/_git/repo');
    });
    test('other servers and local folders', () {
      final gitea = RemoteHost.parse('https://codeberg.org/me/thing.git');
      expect(gitea.kind, RemoteHostKind.otherGit);
      expect(gitea.label, 'codeberg.org');
      expect(
        RemoteHost.parse('/Users/me/backups/thing.git').kind,
        RemoteHostKind.localFolder,
      );
      expect(
        RemoteHost.parse('file:///srv/git/thing.git').kind,
        RemoteHostKind.localFolder,
      );
      expect(
        RemoteHost.parse('C:/repos/thing').kind,
        RemoteHostKind.localFolder,
      );
    });
  });

  test('custom titles are cosmetic and persist', () {
    final repo = TrackedRepo(path: '/work/client-x-backend', addedAt: DateTime(2026));
    expect(repo.title, 'client-x-backend');
    final renamed = repo.copyWith(displayName: 'Backend');
    expect(renamed.title, 'Backend');
    expect(renamed.name, 'client-x-backend');
    expect(TrackedRepo.fromJson(renamed.toJson())!.title, 'Backend');
    expect(renamed.copyWith(clearDisplayName: true).title, 'client-x-backend');
  });

  test('host filter labels', () {
    expect(remoteHostFilterLabel(RemoteHostKind.gitlab), 'GitLab');
    expect(remoteHostFilterLabel(RemoteHostKind.otherGit), 'Other Git servers');
    expect(remoteHostFilterLabel(null), startsWith('No remote'));
  });

  test('pinned flag round-trips and toggles', () {
    final repo = TrackedRepo(path: '/work/app', addedAt: DateTime(2026));
    expect(repo.pinned, isFalse);
    final pinned = repo.copyWith(pinned: true);
    expect(TrackedRepo.fromJson(pinned.toJson())!.pinned, isTrue);
    // Other edits keep the pin.
    expect(pinned.copyWith(displayName: 'App').pinned, isTrue);
    // Old saved data without the field loads as unpinned.
    expect(
      TrackedRepo.fromJson({'path': '/work/app', 'addedAt': '2026-01-01'})!.pinned,
      isFalse,
    );
  });

  test('a branch that exists online but is not linked says so', () {
    const status = RepoStatus(
      branch: 'main',
      upstream: null,
      ahead: 0,
      behind: 0,
      changes: [],
      headOid: 'abc',
    );
    expect(SyncStatusPill.describe(status).$2, 'Not published');
    final (IconData _, String label) = SyncStatusPill.describe(
      status,
      remoteBranch: 'origin/main',
    );
    expect(label, 'Not linked');
  });
}
