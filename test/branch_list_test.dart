import 'package:flutter_test/flutter_test.dart';
import 'package:gitty/services/git/workflow_models.dart';

void main() {
  test('branch list: local first, online-only ones without a local copy', () {
    final list = parseBranchSummaries(
      'refs/heads/feature/x\t1700000300\torigin/feature/x\tAdd login\n'
      'refs/remotes/origin/HEAD\t1700000200\t\tMerge\n'
      'refs/remotes/origin/feature/x\t1700000250\t\tAdd login\n'
      'refs/heads/main\t1700000200\torigin/main\tMerge\n'
      'refs/remotes/origin/dev\t1700000100\t\tWork in progress\n',
    );
    expect(list.map((b) => b.name), ['feature/x', 'main', 'dev']);
    expect(list.first.upstream, 'origin/feature/x');
    expect(list.first.subject, 'Add login');
    expect(list.last.remoteOnly, isTrue);
  });
}
