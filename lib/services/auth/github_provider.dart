import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/errors/gitty_exception.dart';
import 'git_provider.dart';
import 'token_store.dart';

/// GitHub sign-in using the OAuth Device Flow.
///
/// Requires an OAuth App (or GitHub App) with "Device Flow" enabled. Gitty
/// ships with its own client id (see `githubClientId`); override it at build
/// time with `--dart-define=GITHUB_CLIENT_ID=...`.
/// No client secret is needed (or stored).
class GitHubProvider implements GitHostingProvider {
  GitHubProvider({
    required this.clientId,
    required TokenStore tokenStore,
    http.Client? client,
  }) : _tokens = tokenStore,
       _http = client ?? http.Client();

  final String clientId;
  final TokenStore _tokens;
  final http.Client _http;

  /// `repo` to clone/push/create repositories, `workflow` so pushes that
  /// touch `.github/workflows` aren't rejected, `read:user` for the profile,
  /// `read:org` to offer your organizations as owners for new repositories.
  static const _scopes = 'repo workflow read:user read:org';

  /// Upper bound for the repository picker (100 per page).
  static const _maxRepoPages = 10;
  static const _apiBase = 'https://api.github.com';

  @override
  GitProviderKind get kind => GitProviderKind.github;

  @override
  bool get isConfigured => clientId.isNotEmpty;

  @override
  Future<ProviderAccount?> restoreSession() async {
    final token = await _tokens.read(kind.name);
    if (token == null) return null;
    try {
      return await _fetchAccount(token);
    } on GittyException {
      // Token revoked or expired — forget it quietly.
      await _tokens.delete(kind.name);
      return null;
    } catch (_) {
      // Offline: keep the token, but we can't show account details yet.
      return ProviderAccount(kind: kind, username: 'GitHub account');
    }
  }

  @override
  Future<DeviceCodeChallenge> startSignIn() async {
    final res = await _http
        .post(
          Uri.parse('https://github.com/login/device/code'),
          headers: {'Accept': 'application/json'},
          body: {'client_id': clientId, 'scope': _scopes},
        )
        .timeout(const Duration(seconds: 20));
    final json = _decode(res);
    if (res.statusCode != 200 || json['device_code'] == null) {
      throw GittyException(
        "GitHub didn't start the sign-in.",
        hint: 'Check that the OAuth app has Device Flow enabled.',
        details: res.body,
      );
    }
    return DeviceCodeChallenge(
      deviceCode: json['device_code'] as String,
      userCode: json['user_code'] as String,
      verificationUri: Uri.parse(json['verification_uri'] as String),
      expiresAt: DateTime.now().add(
        Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 900),
      ),
      interval: Duration(seconds: (json['interval'] as num?)?.toInt() ?? 5),
    );
  }

  @override
  Future<ProviderAccount> completeSignIn(
    DeviceCodeChallenge challenge, {
    bool Function()? isCancelled,
  }) async {
    var interval = challenge.interval;
    while (DateTime.now().isBefore(challenge.expiresAt)) {
      await Future<void>.delayed(interval);
      if (isCancelled?.call() ?? false) throw const SignInCancelled();

      final res = await _http
          .post(
            Uri.parse('https://github.com/login/oauth/access_token'),
            headers: {'Accept': 'application/json'},
            body: {
              'client_id': clientId,
              'device_code': challenge.deviceCode,
              'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            },
          )
          .timeout(const Duration(seconds: 20));
      final json = _decode(res);

      final token = json['access_token'] as String?;
      if (token != null) {
        final account = await _fetchAccount(token);
        await _tokens.write(kind.name, token);
        return account;
      }

      final error = json['error'] as String?;
      if (error == 'authorization_pending') {
        // User hasn't approved yet — keep polling.
      } else if (error == 'slow_down') {
        interval += const Duration(seconds: 5);
      } else if (error == 'access_denied') {
        throw const GittyException('Sign-in was declined on GitHub.');
      } else if (error == 'expired_token') {
        throw const GittyException(
          'The sign-in code expired.',
          hint: 'Start again to get a fresh code.',
        );
      } else {
        throw GittyException(
          "GitHub sign-in didn't complete.",
          details: res.body,
        );
      }
    }
    throw const GittyException(
      'The sign-in code expired.',
      hint: 'Start again to get a fresh code.',
    );
  }

  @override
  Future<void> signOut() => _tokens.delete(kind.name);

  @override
  Future<List<RemoteRepository>> listRepositories() async {
    final token = await _tokens.read(kind.name);
    if (token == null) return const [];
    final repos = <RemoteRepository>[];
    for (var page = 1; page <= _maxRepoPages; page++) {
      final res = await _http
          .get(
            Uri.parse(
              '$_apiBase/user/repos?sort=updated&per_page=100&page=$page',
            ),
            headers: _apiHeaders(token),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        if (repos.isNotEmpty) break; // Show what we already have.
        throw GittyException(
          "Couldn't load your GitHub repositories.",
          details: res.body,
        );
      }
      final list = jsonDecode(res.body);
      if (list is! List) break;
      repos.addAll(list.whereType<Map<String, dynamic>>().map(_repoFromJson));
      if (list.length < 100) break;
    }
    return repos;
  }

  @override
  Future<List<RepoOwner>> listOwners() async {
    final token = await _requireToken();
    final account = await _fetchAccount(token);
    final owners = [
      RepoOwner(login: account.username, avatarUrl: account.avatarUrl),
    ];
    try {
      final res = await _http
          .get(
            Uri.parse('$_apiBase/user/orgs?per_page=100'),
            headers: _apiHeaders(token),
          )
          .timeout(const Duration(seconds: 20));
      final list = res.statusCode == 200 ? jsonDecode(res.body) : null;
      if (list is List) {
        for (final org in list.whereType<Map<String, dynamic>>()) {
          final login = org['login'] as String?;
          if (login == null) continue;
          owners.add(
            RepoOwner(
              login: login,
              isOrganization: true,
              avatarUrl: org['avatar_url'] as String?,
            ),
          );
        }
      }
    } catch (_) {
      // Organizations are optional — personal account always works.
    }
    return owners;
  }

  @override
  Future<RemoteRepository> createRepository({
    required String name,
    String? description,
    bool isPrivate = true,
    String? organization,
  }) async {
    final token = await _requireToken();
    final url = organization == null
        ? '$_apiBase/user/repos'
        : '$_apiBase/orgs/$organization/repos';
    final res = await _http
        .post(
          Uri.parse(url),
          headers: {
            ..._apiHeaders(token),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'name': name,
            if (description != null && description.trim().isNotEmpty)
              'description': description.trim(),
            'private': isPrivate,
            // Empty on purpose: the local folder's first push goes through
            // cleanly, with no unrelated README commit to merge.
            'auto_init': false,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode == 201) return _repoFromJson(_decode(res));

    final where = organization ?? 'your account';
    if (res.statusCode == 401) {
      throw const GittyException(
        'Your GitHub session has expired.',
        hint: 'Please connect again.',
      );
    }
    if (res.statusCode == 422) {
      final body = res.body.toLowerCase();
      if (body.contains('already exists')) {
        throw GittyException(
          'There’s already a repository called “$name” on $where.',
          hint: 'Pick another name — or choose it under “Use existing”.',
          details: res.body,
        );
      }
      throw GittyException(
        'GitHub didn’t accept that repository name.',
        hint: 'Use letters, numbers, dots, dashes and underscores.',
        details: res.body,
      );
    }
    if (res.statusCode == 403 || res.statusCode == 404) {
      throw GittyException(
        'GitHub didn’t let Gitty create a repository on $where.',
        hint: organization != null
            ? 'The organization may need to approve Gitty (its Settings → '
                  'Third-party access), or you may not be allowed to create '
                  'repositories there.'
            : 'Disconnect GitHub in Settings and connect again to refresh '
                  'Gitty’s permissions.',
        details: res.body,
      );
    }
    throw GittyException(
      'GitHub couldn’t create the repository.',
      hint: 'Try again in a moment.',
      details: res.body,
    );
  }

  Future<String> _requireToken() async {
    final token = await _tokens.read(kind.name);
    if (token == null) {
      throw const GittyException(
        'GitHub isn’t connected.',
        hint: 'Connect your account first.',
      );
    }
    return token;
  }

  static RemoteRepository _repoFromJson(Map<String, dynamic> item) =>
      RemoteRepository(
        fullName: item['full_name'] as String? ?? '',
        cloneUrl: item['clone_url'] as String? ?? '',
        sshUrl: item['ssh_url'] as String?,
        description: item['description'] as String?,
        isPrivate: item['private'] as bool? ?? false,
        updatedAt: DateTime.tryParse(item['updated_at'] as String? ?? ''),
      );

  Future<ProviderAccount> _fetchAccount(String token) async {
    final res = await _http
        .get(Uri.parse('$_apiBase/user'), headers: _apiHeaders(token))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401) {
      throw const GittyException(
        'Your GitHub session has expired.',
        hint: 'Please connect again.',
      );
    }
    final json = _decode(res);
    return ProviderAccount(
      kind: kind,
      username: json['login'] as String? ?? 'unknown',
      displayName: json['name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      id: (json['id'] as num?)?.toInt(),
    );
  }

  Map<String, String> _apiHeaders(String token) => {
    'Accept': 'application/vnd.github+json',
    'Authorization': 'Bearer $token',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  Map<String, dynamic> _decode(http.Response res) {
    try {
      final decoded = jsonDecode(res.body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}
