import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/services/ai/commit_style.dart';
import 'package:gitty/services/ai/diff_digest.dart';
import 'package:gitty/services/ai/prompt_builder.dart';

const _diff = '''
diff --git a/lib/auth.dart b/lib/auth.dart
index 1111111..2222222 100644
--- a/lib/auth.dart
+++ b/lib/auth.dart
@@ -10,6 +10,9 @@ class AuthService {
 import 'x.dart';
+import 'package:mail/mail.dart';
+
+  Future<void> sendResetLink(String email) async {
+    await _mail.send(email, _resetTemplate);
+  }
   }
-  void oldThing() {}
diff --git a/assets/logo.png b/assets/logo.png
new file mode 100644
Binary files /dev/null and b/assets/logo.png differ
''';

void main() {
  test('digest keeps meaning and drops noise', () {
    final d = digestDiff(_diff);
    expect(d, contains('lib/auth.dart (+5 −1)'));
    expect(d, contains('in: class AuthService'));
    expect(d, contains('(imports changed)'));
    expect(d, contains('+ Future<void> sendResetLink(String email) async {'));
    expect(d, contains('- void oldThing() {}'));
    expect(d, isNot(contains('import \'package:mail')));
    expect(d, contains('assets/logo.png (+0 −0) [binary]'));
  });

  test('digest respects its size limit roughly', () {
    final big = StringBuffer();
    for (var f = 0; f < 30; f++) {
      big.writeln('diff --git a/f$f.dart b/f$f.dart');
      big.writeln('@@ -1 +1 @@');
      for (var i = 0; i < 200; i++) {
        big.writeln('+  final value$i = compute($i);');
      }
    }
    final d = digestDiff(big.toString(), maxChars: 4500);
    // Every file is still mentioned.
    for (var f = 0; f < 30; f++) {
      expect(d, contains('f$f.dart (+200 −0)'));
    }
    expect(d.length, lessThan(4500 + 30 * 200));
  });

  test('bad commit messages are caught', () {
    const p = CommitPromptBuilder();
    expect(p.problemWith('This commit adds stuff', CommitStyle.short, []), isNotNull);
    expect(p.problemWith('Add login', CommitStyle.conventional, []), isNotNull);
    expect(p.problemWith('feat(auth): add password reset', CommitStyle.conventional, []), isNull);
    expect(
      p.problemWith('Update a.dart and b.dart', CommitStyle.short, ['lib/a.dart', 'lib/b.dart']),
      isNotNull,
    );
    expect(p.problemWith('chore: update files', CommitStyle.conventional, []), isNotNull);
  });
}
