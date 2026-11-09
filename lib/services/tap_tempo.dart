/// Turns taps into a BPM: the average interval of the last [window] taps,
/// starting over after [resetAfter] without a tap.
class TapTempo {
  TapTempo({this.window = 8, this.resetAfter = const Duration(seconds: 2)});

  final int window;
  final Duration resetAfter;
  final List<Duration> _taps = [];

  /// Records a tap at [at] (time since any fixed origin) and returns the
  /// current estimate, or null until there are two taps.
  double? tap(Duration at) {
    if (_taps.isNotEmpty && (at - _taps.last > resetAfter || at < _taps.last)) {
      _taps.clear();
    }
    _taps.add(at);
    if (_taps.length > window) _taps.removeAt(0);
    return bpm;
  }

  int get count => _taps.length;

  double? get bpm {
    if (_taps.length < 2) return null;
    final span = _taps.last - _taps.first;
    if (span <= Duration.zero) return null;
    return 60000000 * (_taps.length - 1) / span.inMicroseconds;
  }

  void reset() => _taps.clear();
}
