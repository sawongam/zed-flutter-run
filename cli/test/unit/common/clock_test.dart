import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_run/src/common/clock.dart';
import 'package:flutter_run/src/watch/coalescer.dart';
import 'package:test/test.dart';

/// A clock that counts the timers it hands out, to show the injection works.
class _CountingClock extends SystemClock {
  int timers = 0;
  @override
  Timer timer(Duration d, void Function() cb) {
    timers++;
    return super.timer(d, cb);
  }
}

void main() {
  test('ReloadCoalescer arms its debounce through the injected clock', () {
    fakeAsync((async) {
      final clock = _CountingClock();
      var reloads = 0;
      ReloadCoalescer(
        debounce: const Duration(milliseconds: 100),
        reload: () async {
          reloads++;
          return ReloadResult.done;
        },
        clock: clock,
      ).notifyChange();
      expect(clock.timers, 1);
      async.elapse(const Duration(milliseconds: 150));
      expect(reloads, 1);
    });
  });
}
