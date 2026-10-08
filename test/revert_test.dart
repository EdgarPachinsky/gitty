import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/features/repository/widgets/revert_dialog.dart';
import 'package:gitty/services/git/git_models.dart';
import 'package:gitty/services/storage/settings_repository.dart';

void main() {
  test('dashboard panel state is remembered', () {
    const s = AppSettings();
    expect(s.pinnedSectionExpanded, isTrue);
    final collapsed = s.copyWith(pinnedSectionExpanded: false);
    final restored = AppSettings.fromJson(collapsed.toJson());
    expect(restored.pinnedSectionExpanded, isFalse);
    expect(restored.otherSectionExpanded, isTrue);
  });

  testWidgets('revert dialog explains what happens and asks first', (
    tester,
  ) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => answer = await confirmRevert(
              context,
              all: true,
              canUndo: true,
              changes: const [
                FileChange(
                  path: 'lib/a.dart',
                  kind: FileChangeKind.modified,
                  staged: false,
                  unstaged: true,
                ),
                FileChange(
                  path: 'notes.txt',
                  kind: FileChangeKind.untracked,
                  staged: false,
                  unstaged: true,
                ),
              ],
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Revert all changes?'), findsOneWidget);
    expect(find.textContaining('1 changed file goes back'), findsOneWidget);
    expect(find.textContaining('1 new file is removed'), findsOneWidget);
    expect(find.textContaining('Undo'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });
}
