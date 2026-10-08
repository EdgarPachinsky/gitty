import 'dart:async';
import 'dart:collection';

/// Runs at most [maxConcurrent] tasks at a time; the rest wait their turn
/// (first come, first served).
class TaskLimiter {
  TaskLimiter(this.maxConcurrent) : assert(maxConcurrent > 0);

  final int maxConcurrent;
  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running < maxConcurrent) {
      _running++;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future; // the finishing task hands its slot over
    }
    try {
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}

/// Thrown inside a limited task when the result is no longer wanted (the
/// provider was refreshed or disposed while it waited). Riverpod ignores it.
class RefreshSkipped implements Exception {
  const RefreshSkipped();
}
