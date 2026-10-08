import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/services/git/gitignore_templates.dart';

void main() {
  GitignoreTemplate t(String id) => gitignoreTemplateById(id)!;

  test('detects project types from top-level names', () {
    expect(
      detectGitignoreTemplates(['pubspec.yaml', 'lib', 'README.md']),
      {'flutter'},
    );
    expect(detectGitignoreTemplates(['package.json', 'main.py']), {
      'node',
      'python',
    });
    expect(detectGitignoreTemplates(['App.xcodeproj']), {'swift'});
    expect(detectGitignoreTemplates(['notes.txt']), isEmpty);
  });

  test('a new file has a header, sections and no duplicate rules', () {
    final content = buildGitignore([t('flutter'), t('node')]);
    expect(content, startsWith('# .gitignore — created with Gitty.'));
    expect(content, contains('# Flutter / Dart — Build output'));
    // build/ is in both templates but written once.
    expect(RegExp(r'^build/$', multiLine: true).allMatches(content).length, 1);
    expect(gitignoreRules(content), containsAll(['node_modules/', '.dart_tool/']));
  });

  test('appending only adds rules the file does not have yet', () {
    const existing = '# mine\n.DS_Store\nbuild/\n';
    final block = buildGitignore([t('macos')], existing: existing);
    expect(block, startsWith('\n# ── Added by Gitty ──'));
    expect(gitignoreRules(block), isNot(contains('.DS_Store')));
    expect(gitignoreRules(block), contains('.AppleDouble'));
  });

  test('nothing new means nothing to write', () {
    final full = buildGitignore([t('logs')]);
    expect(buildGitignore([t('logs')], existing: full), isEmpty);
  });

  test('custom rules are included', () {
    final content = buildGitignore(const [], custom: [' secrets.json ', '']);
    expect(gitignoreRules(content), {'secrets.json'});
    expect(content, contains('# Your own rules'));
  });
}
