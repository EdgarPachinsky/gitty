import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/core/widgets/state_views.dart';
import 'package:gitty/services/ai/commit_style.dart';
import 'package:gitty/services/ai/commit_message_service.dart';
import 'package:gitty/services/ai/draft_commit_message_service.dart';
import 'package:gitty/services/ai/prompt_builder.dart';

void main() {
  testWidgets('EmptyState shows title, message and actions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmptyState(
            icon: Icons.folder_open,
            title: 'No repositories yet',
            message: 'Add one to get started.',
            actions: [FilledButton(onPressed: () {}, child: const Text('Add'))],
          ),
        ),
      ),
    );

    expect(find.text('No repositories yet'), findsOneWidget);
    expect(find.text('Add one to get started.'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
  });

  test('draft commit messages follow the chosen style', () async {
    const service = DraftCommitMessageService();
    Future<String> gen(CommitStyle style, List<String> files) async =>
        (await service.generate(
          CommitMessageRequest(
            diff: '',
            diffStat: '',
            stagedFiles: files,
            style: style,
          ),
        )).message;

    expect(
      await gen(CommitStyle.conventional, ['README.md']),
      startsWith('docs'),
    );
    expect(
      await gen(CommitStyle.short, ['lib/a.dart', 'lib/b.dart']),
      'Update 2 files in lib',
    );
  });

  test('cleanModelOutput strips fences, quotes and reasoning', () {
    expect(cleanModelOutput('```\nfeat: add x\n```'), 'feat: add x');
    expect(cleanModelOutput('"fix: typo"'), 'fix: typo');
    expect(cleanModelOutput('<think>hmm</think>\nchore: tidy'), 'chore: tidy');
  });
}
