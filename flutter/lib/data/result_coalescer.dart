import 'dart:async';

/// 100 ms latest-wins flush (edge-studio pattern, ported from the Swift
/// ResultCoalescer). Observer emissions during a sync storm would otherwise
/// re-render the UI per row; here the UI sees at most one delivery per
/// window, carrying the settled state. Dart's event loop is single-threaded,
/// so the lock is implicit — but the latest-wins semantics match the other
/// platforms exactly.
class ResultCoalescer<T> {
  ResultCoalescer({required this.onChange, this.flushInterval = const Duration(milliseconds: 100)});

  final void Function(T) onChange;
  final Duration flushInterval;

  T? _pending;
  bool _flushScheduled = false;
  Timer? _timer;

  void enqueue(T value) {
    _pending = value;
    if (_flushScheduled) return;
    _flushScheduled = true;
    _timer = Timer(flushInterval, flush);
  }

  void flush() {
    final value = _pending;
    _pending = null;
    _flushScheduled = false;
    if (value != null) onChange(value);
  }

  void dispose() {
    _timer?.cancel();
    _pending = null;
    _flushScheduled = false;
  }
}
