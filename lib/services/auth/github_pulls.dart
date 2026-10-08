import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/errors/gitty_exception.dart';
import 'git_provider.dart';
import 'token_store.dart';

class PullRequestInfo {
  const PullRequestInfo({
    required this.number,
    required this.title,
    required this.state,
    required this.draft,
    required this.merged,
    required this.url,
    required this.base,
    required this.head,
    required this.headSha,
    this.mergeableState,
    this.requestedReviewers = const [],
  });

  final int number;
  final String title;

  /// "open" or "closed".
  final String state;
  final bool draft;
  final bool merged;
  final Uri url;
  final String base;
  final String head;
  final String headSha;

  /// GitHub's "clean", "dirty" (has conflicts), "blocked", "behind", … —
  /// only present when fetched one by one.
  final String? mergeableState;
  final List<String> requestedReviewers;

  bool get isOpen => state == 'open';

  static PullRequestInfo fromJson(Map<String, dynamic> j) => PullRequestInfo(
    number: (j['number'] as num?)?.toInt() ?? 0,
    title: j['title'] as String? ?? '',
    state: j['state'] as String? ?? 'open',
    draft: j['draft'] as bool? ?? false,
    merged: j['merged'] as bool? ?? (j['merged_at'] != null),
    url: Uri.tryParse(j['html_url'] as String? ?? '') ?? Uri(),
    base: (j['base'] as Map?)?['ref'] as String? ?? '',
    head: (j['head'] as Map?)?['ref'] as String? ?? '',
    headSha: (j['head'] as Map?)?['sha'] as String? ?? '',
    mergeableState: j['mergeable_state'] as String?,
    requestedReviewers: [
      for (final r in (j['requested_reviewers'] as List? ?? const []))
        if (r is Map && r['login'] is String) r['login'] as String,
    ],
  );
}

/// Automated checks (CI) on the pull request's latest commit.
class PrChecks {
  const PrChecks({this.passed = 0, this.failed = 0, this.running = 0});

  final int passed;
  final int failed;
  final int running;

  int get total => passed + failed + running;
}

/// Latest review per person.
class PrReviews {
  const PrReviews({
    this.approvedBy = const [],
    this.changesRequestedBy = const [],
  });

  final List<String> approvedBy;
  final List<String> changesRequestedBy;
}

/// Pull requests on GitHub, with the account connected in Settings.
class GitHubPulls {
  GitHubPulls({required TokenStore tokens, http.Client? client})
    : _tokens = tokens,
      _http = client ?? http.Client();

  final TokenStore _tokens;
  final http.Client _http;
  static const _api = 'https://api.github.com';

  Future<String> _token() async {
    final token = await _tokens.read(GitProviderKind.github.name);
    if (token == null || token.isEmpty) {
      throw const GittyException(
        'GitHub isn’t connected.',
        hint: 'Connect GitHub in Settings to work with pull requests here.',
      );
    }
    return token;
  }

  Future<Object?> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final token = await _token();
    final uri = Uri.parse('$_api$path');
    final headers = {
      'Accept': 'application/vnd.github+json',
      'Authorization': 'Bearer $token',
      'X-GitHub-Api-Version': '2022-11-28',
      if (body != null) 'Content-Type': 'application/json',
    };
    final res = await (method == 'POST'
            ? _http.post(uri, headers: headers, body: jsonEncode(body))
            : _http.get(uri, headers: headers))
        .timeout(const Duration(seconds: 20));
    Object? decoded;
    try {
      decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      decoded = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return decoded;

    final message = decoded is Map ? decoded['message'] as String? : null;
    final errors = decoded is Map ? decoded['errors'] : null;
    final detail = errors is List && errors.isNotEmpty && errors.first is Map
        ? (errors.first as Map)['message'] as String?
        : null;
    if (res.statusCode == 401) {
      throw const GittyException(
        'Your GitHub session has expired.',
        hint: 'Connect GitHub again in Settings.',
      );
    }
    if (res.statusCode == 403 || res.statusCode == 404) {
      throw GittyException(
        'GitHub didn’t let Gitty see this repository’s pull requests.',
        hint:
            'Make sure the account connected in Settings has access to it '
            '(for an organization, it may need to approve Gitty).',
        details: '${res.statusCode} ${message ?? ''}',
      );
    }
    if (res.statusCode == 422) {
      final text = detail ?? message ?? 'GitHub couldn’t do that.';
      if (text.toLowerCase().contains('no commits between')) {
        throw GittyException(
          'There’s nothing to review yet.',
          hint:
              'This branch has no commits that aren’t already in the target '
              'branch. Commit and push some work first.',
          details: text,
        );
      }
      throw GittyException(text, details: res.body);
    }
    throw GittyException(
      'GitHub answered with an error (${res.statusCode}).',
      hint: 'Try again in a moment.',
      details: message ?? res.body,
    );
  }

  /// The pull request for [branch] (open ones first), or null.
  Future<PullRequestInfo?> forBranch(
    String owner,
    String repo,
    String branch,
  ) async {
    final list = await _send(
      'GET',
      '/repos/$owner/$repo/pulls?state=all&per_page=10'
          '&head=${Uri.encodeQueryComponent('$owner:$branch')}',
    );
    if (list is! List || list.isEmpty) return null;
    final prs = [
      for (final item in list)
        if (item is Map<String, dynamic>) PullRequestInfo.fromJson(item),
    ];
    if (prs.isEmpty) return null;
    final open = prs.where((p) => p.isOpen).firstOrNull ?? prs.first;
    // The list doesn't include merge status; fetch the one we show.
    final full = await _send('GET', '/repos/$owner/$repo/pulls/${open.number}');
    return full is Map<String, dynamic> ? PullRequestInfo.fromJson(full) : open;
  }

  Future<PullRequestInfo> create({
    required String owner,
    required String repo,
    required String head,
    required String base,
    required String title,
    required String body,
    bool draft = false,
  }) async {
    final json = await _send(
      'POST',
      '/repos/$owner/$repo/pulls',
      body: {
        'title': title,
        'head': head,
        'base': base,
        'body': body,
        'draft': draft,
      },
    );
    if (json is! Map<String, dynamic>) {
      throw const GittyException('GitHub gave an unexpected answer.');
    }
    return PullRequestInfo.fromJson(json);
  }

  /// CI results for [sha] (GitHub Actions and older status checks).
  Future<PrChecks> checks(String owner, String repo, String sha) async {
    var passed = 0, failed = 0, running = 0;
    final runs = await _send(
      'GET',
      '/repos/$owner/$repo/commits/$sha/check-runs?per_page=100',
    );
    if (runs is Map && runs['check_runs'] is List) {
      for (final r in runs['check_runs'] as List) {
        if (r is! Map) continue;
        if (r['status'] != 'completed') {
          running++;
        } else {
          switch (r['conclusion']) {
            case 'success' || 'neutral' || 'skipped':
              passed++;
            default:
              failed++;
          }
        }
      }
    }
    final status = await _send('GET', '/repos/$owner/$repo/commits/$sha/status');
    if (status is Map && status['statuses'] is List) {
      for (final s in status['statuses'] as List) {
        if (s is! Map) continue;
        switch (s['state']) {
          case 'success':
            passed++;
          case 'pending':
            running++;
          default:
            failed++;
        }
      }
    }
    return PrChecks(passed: passed, failed: failed, running: running);
  }

  Future<PrReviews> reviews(String owner, String repo, int number) async {
    final list = await _send(
      'GET',
      '/repos/$owner/$repo/pulls/$number/reviews?per_page=100',
    );
    final latest = <String, String>{};
    if (list is List) {
      for (final r in list) {
        if (r is! Map) continue;
        final user = (r['user'] as Map?)?['login'] as String?;
        final state = r['state'] as String?;
        if (user == null || state == null || state == 'COMMENTED') continue;
        latest[user] = state; // later reviews replace earlier ones
      }
    }
    return PrReviews(
      approvedBy: [
        for (final e in latest.entries)
          if (e.value == 'APPROVED') e.key,
      ],
      changesRequestedBy: [
        for (final e in latest.entries)
          if (e.value == 'CHANGES_REQUESTED') e.key,
      ],
    );
  }
}
