import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

extension CacheForExtension on Ref {
  /// Keeps an auto-dispose provider alive for [duration] after its last
  /// listener goes away (e.g. a dashboard card scrolled out of view), so
  /// coming back shows the value instantly instead of reloading it.
  void cacheFor(Duration duration) {
    final link = keepAlive();
    Timer? timer;
    onCancel(() {
      timer?.cancel();
      timer = Timer(duration, link.close);
    });
    onResume(() => timer?.cancel());
    onDispose(() => timer?.cancel());
  }
}
