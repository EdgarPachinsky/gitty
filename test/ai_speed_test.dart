import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/services/ai/ollama_client.dart';
import 'package:gitty/services/ai/prompt_builder.dart';
import 'package:gitty/services/ai/commit_style.dart';
import 'package:gitty/services/git/git_service.dart';

void main() {
  group('fastest thinking setting', () {
    test('non-thinking model: send nothing', () {
      const info = OllamaModelInfo(canThink: false);
      expect(info.fastThinkSetting, isNull);
      expect(info.answersDirectly, isTrue);
    });
    test('thinking model without levels: switch it off', () {
      const info = OllamaModelInfo(canThink: true);
      expect(info.fastThinkSetting, false);
      expect(info.answersDirectly, isTrue);
    });
    test('gpt-oss style levels: pick low', () {
      const info = OllamaModelInfo(
        canThink: true,
        thinkValues: ['low', 'medium', 'high'],
      );
      expect(info.fastThinkSetting, 'low');
      expect(info.answersDirectly, isFalse);
    });
    test('explicit on/off: off', () {
      const info = OllamaModelInfo(canThink: true, thinkValues: [true, false]);
      expect(info.fastThinkSetting, false);
    });
  });

  test('big diffs are capped per file and overall', () {
    final big = List.filled(400, '+line').join('\n');
    final diff = [
      for (final name in ['a', 'b', 'c', 'd'])
        'diff --git a/$name b/$name\n--- a/$name\n+++ b/$name\n$big\n',
    ].join();
    final out = GitService.compactDiff(diff, maxChars: 3000, perFileChars: 1000);
    expect(out.length, lessThan(3200));
    expect(out, contains('more lines in this file'));
    expect(out, contains('more files changed'));
    expect(out, startsWith('diff --git a/a b/a'));
  });

  test('small diffs pass through untouched', () {
    const diff = 'diff --git a/x b/x\n+hi\n';
    expect(
      GitService.compactDiff(diff, maxChars: 6000, perFileChars: 2000),
      diff,
    );
  });

  test('local prompt asks for a quick answer', () {
    const p = CommitPromptBuilder();
    expect(p.system(CommitStyle.short, quick: true), contains('answer right away'));
    expect(p.system(CommitStyle.short), isNot(contains('answer right away')));
  });
}
