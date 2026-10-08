import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth/git_provider.dart';
import '../../services/service_providers.dart';

/// The connected GitHub account (null when not connected).
class AccountController extends AsyncNotifier<ProviderAccount?> {
  @override
  Future<ProviderAccount?> build() =>
      ref.watch(githubProvider).restoreSession();

  GitHostingProvider get _provider => ref.read(githubProvider);

  bool get isDemoMode => !_provider.isConfigured;

  Future<DeviceCodeChallenge> startSignIn() => _provider.startSignIn();

  Future<ProviderAccount> completeSignIn(
    DeviceCodeChallenge challenge, {
    bool Function()? isCancelled,
  }) async {
    final account = await _provider.completeSignIn(
      challenge,
      isCancelled: isCancelled,
    );
    state = AsyncData(account);
    return account;
  }

  Future<void> signOut() async {
    await _provider.signOut();
    state = const AsyncData(null);
  }
}

final accountProvider =
    AsyncNotifierProvider<AccountController, ProviderAccount?>(
      AccountController.new,
    );

/// Repositories of the connected account, for the clone dialog.
final remoteReposProvider = FutureProvider.autoDispose<List<RemoteRepository>>((
  ref,
) async {
  final account = ref.watch(accountProvider).value;
  if (account == null) return const [];
  return ref.watch(githubProvider).listRepositories();
});

/// Where a new repository can be created: your account, then your orgs.
final repoOwnersProvider = FutureProvider.autoDispose<List<RepoOwner>>((
  ref,
) async {
  final account = ref.watch(accountProvider).value;
  if (account == null) return const [];
  return ref.watch(githubProvider).listOwners();
});
