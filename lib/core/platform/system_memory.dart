import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Total memory of this computer in GB (rounded), or null if unknown.
Future<int?> totalMemoryGb() async {
  try {
    int? bytes;
    if (Platform.isMacOS) {
      final r = await Process.run('sysctl', ['-n', 'hw.memsize']);
      bytes = int.tryParse('${r.stdout}'.trim());
    } else if (Platform.isLinux) {
      final line = (await File('/proc/meminfo').readAsLines()).firstWhere(
        (l) => l.startsWith('MemTotal:'),
        orElse: () => '',
      );
      final kb = int.tryParse(
        RegExp(r'(\d+)').firstMatch(line)?.group(1) ?? '',
      );
      bytes = kb == null ? null : kb * 1024;
    } else if (Platform.isWindows) {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory',
      ]);
      bytes = int.tryParse('${r.stdout}'.trim());
    }
    if (bytes == null || bytes <= 0) return null;
    return (bytes / (1024 * 1024 * 1024)).round();
  } catch (_) {
    return null;
  }
}

final totalMemoryGbProvider = FutureProvider<int?>((ref) => totalMemoryGb());
