import 'dart:async';

class CompletedGate {
  const CompletedGate._();

  static const Duration maxRemaining = Duration(milliseconds: 1200);
  static const Duration audioMinDelay = Duration(milliseconds: 1200);
  static const Duration videoMinDelay = Duration(milliseconds: 800);
  static const Duration maxDelay = Duration(milliseconds: 1500);
  static const Duration buffer = Duration(milliseconds: 200);

  static Duration? remaining({
    required Duration total,
    required Duration position,
  }) {
    if (total <= Duration.zero) {
      return null;
    }
    final remaining = total - position;
    if (remaining > maxRemaining) {
      return null;
    }
    return remaining <= Duration.zero ? Duration.zero : remaining;
  }

  static Duration delay(Duration remaining, {required Duration minDelay}) {
    final delayMs = (remaining + buffer).inMilliseconds.clamp(
      minDelay.inMilliseconds,
      maxDelay.inMilliseconds,
    );
    return Duration(milliseconds: delayMs.toInt());
  }
}

class CompletedGateScheduler {
  Timer? _timer;
  int _token = 0;

  bool cancel() {
    final hadPending = _timer != null;
    _token += 1;
    _timer?.cancel();
    _timer = null;
    return hadPending;
  }

  void schedule(Duration delay, void Function() onFire) {
    final token = ++_token;
    _timer?.cancel();
    _timer = Timer(delay, () {
      if (token != _token) {
        return;
      }
      _timer = null;
      onFire();
    });
  }
}
