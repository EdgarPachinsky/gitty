import 'dart:convert';

import '../../core/errors/gitty_exception.dart';
import '../storage/local_store.dart';
import 'git_provider.dart';

/// Offline stand-in for [GitHubProvider], used when no GITHUB_CLIENT_ID is
/// configured. It walks through the exact same device-flow UI so the
/// experience can be built and tested without real credentials.
class DemoGitHubProvider implements GitHostingProvider {
  DemoGitHubProvider(this._store);

  final LocalStore _store;
  static const _key = 'demo_github_account';

  @override
  GitProviderKind get kind => GitProviderKind.github;

  @override
  bool get isConfigured => false;

  @override
  Future<ProviderAccount?> restoreSession() async {
    final json = LocalStore.readJson(_store.settings, _key);
    return json == null ? null : ProviderAccount.fromJson(json);
  }

  @override
  Future<DeviceCodeChallenge> startSignIn() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return DeviceCodeChallenge(
      deviceCode: 'demo',
      userCode: 'GITY-D3MO',
      verificationUri: Uri.parse('https://github.com/login/device'),
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
      interval: const Duration(seconds: 1),
    );
  }

  @override
  Future<ProviderAccount> completeSignIn(
    DeviceCodeChallenge challenge, {
    bool Function()? isCancelled,
  }) async {
    // Pretend the user approves after a few seconds.
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(challenge.interval);
      if (isCancelled?.call() ?? false) throw const SignInCancelled();
    }
    const account = ProviderAccount(
      kind: GitProviderKind.github,
      username: 'demo-octocat',
      displayName: 'Demo Account',
      isDemo: true,
    );
    await _store.settings.put(_key, jsonEncode(account.toJson()));
    return account;
  }

  @override
  Future<void> signOut() => _store.settings.delete(_key);

  @override
  Future<List<RemoteRepository>> listRepositories() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Real public repositories, so cloning actually works in demo mode.
    return const [
      RemoteRepository(
        fullName: 'octocat/Hello-World',
        cloneUrl: 'https://github.com/octocat/Hello-World.git',
        description: 'My first repository on GitHub!',
      ),
      RemoteRepository(
        fullName: 'octocat/Spoon-Knife',
        cloneUrl: 'https://github.com/octocat/Spoon-Knife.git',
        description: 'This repo is for demonstration purposes only.',
      ),
      RemoteRepository(
        fullName: 'github/gitignore',
        cloneUrl: 'https://github.com/github/gitignore.git',
        description: 'A collection of useful .gitignore templates',
      ),
    ];
  }

  @override
  Future<List<RepoOwner>> listOwners() async {
    final account = await restoreSession();
    return [RepoOwner(login: account?.username ?? 'demo-octocat')];
  }

  @override
  Future<RemoteRepository> createRepository({
    required String name,
    String? description,
    bool isPrivate = true,
    String? organization,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    throw const GittyException(
      'Creating repositories needs a real GitHub connection.',
      hint: 'Demo mode only simulates sign-in. Paste a repository URL instead.',
    );
  }
}
