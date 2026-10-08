import 'dart:convert';

import 'package:hive_ce/hive_ce.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Local-first storage backed by Hive.
///
/// Values are stored as JSON strings in plain boxes, which keeps us free of
/// code generation and makes migrations trivial (just read/transform JSON).
class LocalStore {
  LocalStore._(this.settings, this.repos, this.analytics);

  /// App settings (single JSON document under [settingsKey]) plus small
  /// key-value items such as the demo account.
  final Box<String> settings;

  /// Tracked repositories, keyed by absolute path.
  final Box<String> repos;

  /// Append-only analytics events.
  final Box<String> analytics;

  static const settingsKey = 'app_settings';

  static Future<LocalStore> open() async {
    final support = await getApplicationSupportDirectory();
    Hive.init(p.join(support.path, 'gitty_store'));
    final results = await Future.wait([
      Hive.openBox<String>('settings'),
      Hive.openBox<String>('repos'),
      Hive.openBox<String>('analytics'),
    ]);
    return LocalStore._(results[0], results[1], results[2]);
  }

  /// Reads a JSON object from [box], returning null if missing or corrupt.
  static Map<String, dynamic>? readJson(Box<String> box, dynamic key) {
    final raw = box.get(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Hive string keys must be ASCII and at most 255 chars, but file paths can
  /// be long and contain any characters. This derives a stable short key
  /// (two independent 32-bit hashes of the UTF-8 bytes: FNV-1a and djb2).
  static String keyFor(String value) {
    var fnv = 0x811c9dc5;
    var djb = 5381;
    for (final byte in utf8.encode(value)) {
      fnv = ((fnv ^ byte) * 0x01000193) & 0xFFFFFFFF;
      djb = ((djb * 33) + byte) & 0xFFFFFFFF;
    }
    String hex(int v) => v.toRadixString(16).padLeft(8, '0');
    return 'k${hex(fnv)}${hex(djb)}';
  }

  static Future<void> writeJson(
    Box<String> box,
    dynamic key,
    Map<String, dynamic> value,
  ) => box.put(key, jsonEncode(value));
}
