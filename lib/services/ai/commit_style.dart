/// Commit message styles offered by "Generate with AI".
enum CommitStyle {
  conventional('Conventional', 'feat(scope): add login screen'),
  short('Short', 'Add login screen'),
  detailed('Detailed', 'Summary line plus a bullet list of changes'),
  friendly('Friendly', 'A warm, plain-English description');

  const CommitStyle(this.label, this.example);

  final String label;
  final String example;

  static CommitStyle fromName(
    String? name, {
    CommitStyle fallback = CommitStyle.conventional,
  }) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return fallback;
  }
}
