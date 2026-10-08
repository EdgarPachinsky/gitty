import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/services/auth/git_provider.dart';
import 'package:gitty/services/git/git_service.dart';

void main() {
  test('GitHub token is passed via env config, scoped to github.com', () {
    final env = GitService.githubAuthEnvironment('gho_secret');
    expect(env['GIT_CONFIG_COUNT'], '1');
    expect(env['GIT_CONFIG_KEY_0'], 'http.https://github.com/.extraheader');
    final value = env['GIT_CONFIG_VALUE_0']!;
    expect(value, startsWith('AUTHORIZATION: basic '));
    final decoded = utf8.decode(
      base64Decode(value.substring('AUTHORIZATION: basic '.length)),
    );
    expect(decoded, 'x-access-token:gho_secret');
  });

  test('repo name is derived from common URL shapes', () {
    expect(GitService.repoNameFromUrl('https://github.com/a/b.git'), 'b');
    expect(GitService.repoNameFromUrl('git@github.com:a/b.git'), 'b');
    expect(GitService.repoNameFromUrl('https://github.com/a/b/'), 'b');
  });

  test('folder names become valid GitHub repository names', () {
    expect(suggestRepoName('My App!'), 'My-App');
    expect(suggestRepoName('  gitty  '), 'gitty');
    expect(suggestRepoName('---'), 'my-project');
    expect(suggestRepoName('.hidden'), 'hidden');
    expect(validateRepoName('ok-name_1.0'), isNull);
    expect(validateRepoName(''), isNotNull);
    expect(validateRepoName('has space'), isNotNull);
    expect(validateRepoName('..'), isNotNull);
  });
}
