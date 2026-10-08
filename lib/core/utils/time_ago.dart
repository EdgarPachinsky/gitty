/// Compact, friendly relative time ("just now", "5 min ago", "3 days ago").
String timeAgo(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.isNegative || diff.inSeconds < 45) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) {
    return diff.inHours == 1 ? '1 hour ago' : '${diff.inHours} hours ago';
  }
  if (diff.inDays < 7) {
    return diff.inDays == 1 ? 'yesterday' : '${diff.inDays} days ago';
  }
  if (diff.inDays < 30) {
    final weeks = diff.inDays ~/ 7;
    return weeks == 1 ? 'last week' : '$weeks weeks ago';
  }
  if (diff.inDays < 365) {
    final months = diff.inDays ~/ 30;
    return months == 1 ? 'last month' : '$months months ago';
  }
  final years = diff.inDays ~/ 365;
  return years == 1 ? 'last year' : '$years years ago';
}

/// Human duration ("35 min", "2.5 hours", "1.2 days").
String humanDuration(Duration d) {
  if (d.inMinutes < 1) return '< 1 min';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 24) return '${_oneDecimal(d.inMinutes / 60)} hours';
  return '${_oneDecimal(d.inHours / 24)} days';
}

String _oneDecimal(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// "1 file" / "3 files"
String plural(int count, String singular, [String? pluralForm]) =>
    '$count ${count == 1 ? singular : (pluralForm ?? '${singular}s')}';
