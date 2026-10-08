/// Provider-agnostic contracts for Git hosting services.
///
/// GitHub is implemented first; GitLab, Bitbucket and Gitea can be added by
/// implementing [GitHostingProvider] without touching the UI.
library;

enum GitProviderKind {
  github('GitHub'),
  gitlab('GitLab'),
  bitbucket('Bitbucket'),
  gitea('Gitea');

  const GitProviderKind(this.label);
  final String label;
}

class ProviderAccount {
  const ProviderAccount({
    required this.kind,
    required this.username,
    this.displayName,
    this.avatarUrl,
    this.isDemo = false,
    this.id,
  });

  final GitProviderKind kind;

  /// Numeric account id (GitHub), used for the private no-reply email.
  final int? id;
  final String username;
  final String? displayName;
  final String? avatarUrl;

  /// True when signed in with the offline demo provider.
  final bool isDemo;

  /// GitHub's private commit email, e.g. `123+octocat@users.noreply.github.com`.
  /// Commits show up on your profile without exposing your real address.
  String? get noreplyEmail {
    if (kind != GitProviderKind.github || username.isEmpty) return null;
    return id == null
        ? '$username@users.noreply.github.com'
        : '$id+$username@users.noreply.github.com';
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'username': username,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'isDemo': isDemo,
    'id': id,
  };

  static ProviderAccount? fromJson(Map<String, dynamic> json) {
    final username = json['username'] as String?;
    if (username == null) return null;
    return ProviderAccount(
      kind: GitProviderKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => GitProviderKind.github,
      ),
      username: username,
      displayName: json['displayName'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      isDemo: json['isDemo'] as bool? ?? false,
      id: (json['id'] as num?)?.toInt(),
    );
  }
}

class RemoteRepository {
  const RemoteRepository({
    required this.fullName,
    required this.cloneUrl,
    this.sshUrl,
    this.description,
    this.isPrivate = false,
    this.updatedAt,
  });

  final String fullName;
  final String cloneUrl;
  final String? sshUrl;
  final String? description;
  final bool isPrivate;
  final DateTime? updatedAt;

  String get name => fullName.split('/').last;
}

/// An account or organization that can own a new repository.
class RepoOwner {
  const RepoOwner({
    required this.login,
    this.isOrganization = false,
    this.avatarUrl,
  });

  final String login;
  final bool isOrganization;
  final String? avatarUrl;
}

/// Turns a folder name into a valid repository name
/// (letters, digits, `.`, `_`, `-`), e.g. "My App!" → "My-App".
String suggestRepoName(String folderName) {
  var name = folderName
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
  if (name.length > 100) name = name.substring(0, 100);
  return name.isEmpty ? 'my-project' : name;
}

/// Null when [name] is a valid repository name, otherwise a friendly reason.
String? validateRepoName(String name) {
  if (name.isEmpty) return 'Give the repository a name.';
  if (name.length > 100) return 'Keep the name under 100 characters.';
  if (name == '.' || name == '..') return 'That name is reserved.';
  if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) {
    return 'Use letters, numbers, dots, dashes and underscores only.';
  }
  return null;
}

/// OAuth 2.0 Device Authorization Grant challenge — the best fit for desktop
/// apps: no client secret and no local redirect server required.
class DeviceCodeChallenge {
  const DeviceCodeChallenge({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresAt,
    required this.interval,
  });

  final String deviceCode;

  /// Short code the user types on the provider's website.
  final String userCode;
  final Uri verificationUri;
  final DateTime expiresAt;
  final Duration interval;
}

abstract interface class GitHostingProvider {
  GitProviderKind get kind;

  /// False when running without real OAuth credentials (demo mode).
  bool get isConfigured;

  /// Returns the signed-in account from secure storage, if any.
  Future<ProviderAccount?> restoreSession();

  /// Step 1 of sign-in: obtain a code for the user to approve.
  Future<DeviceCodeChallenge> startSignIn();

  /// Step 2: wait until the user approves (polling), then return the account.
  /// Stops early (throwing) if [isCancelled] returns true.
  Future<ProviderAccount> completeSignIn(
    DeviceCodeChallenge challenge, {
    bool Function()? isCancelled,
  });

  Future<void> signOut();

  Future<List<RemoteRepository>> listRepositories();

  /// The signed-in account first, then organizations the user belongs to.
  Future<List<RepoOwner>> listOwners();

  /// Creates an empty repository (no README) on the provider and returns
  /// it. [organization] null means the user's personal account.
  Future<RemoteRepository> createRepository({
    required String name,
    String? description,
    bool isPrivate = true,
    String? organization,
  });
}

class SignInCancelled implements Exception {
  const SignInCancelled();
}
