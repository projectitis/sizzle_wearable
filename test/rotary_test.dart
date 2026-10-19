import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sizzle_wearable/sizzle_wearable.dart';

/// A platform payload, shaped exactly as `SizzleWearablePlugin.emitRotary`
/// builds it.
Map<String, Object> _event(
  double scroll, {
  double? resolution,
  int samples = 1,
  double? scrollFactor,
  int deviceId = 8,
  String? deviceName,
  int eventTimeMs = 0,
}) => <String, Object>{
  'scroll': scroll,
  'deviceId': deviceId,
  'samples': samples,
  'eventTimeMs': eventTimeMs,
  if (resolution != null) 'resolution': resolution,
  if (scrollFactor != null) 'scrollFactor': scrollFactor,
  if (deviceName != null) 'deviceName': deviceName,
};

Rotary _rotary() => Rotary(const EventChannel('test/rotary'));

/// Let queued stream deliveries run before asserting on what a listener saw.
Future<void> _drainMicrotasks() => Future<void>.delayed(Duration.zero);

/// Feed [total] raw scroll units in [pieces] equal events.
double _accumulate(Rotary rotary, double total, int pieces, {double? res}) {
  for (int i = 0; i < pieces; i++) {
    rotary.debugHandleEvent(_event(total / pieces, resolution: res));
  }
  return rotary.consumeAngleDelta();
}

void main() {
  // `consumeAngleDelta` starts the platform listener on first call, and
  // resolving an EventChannel's messenger needs a binding. Without this every
  // test that drains the accumulator fails on the binding assertion rather than
  // on anything to do with rotary.
  TestWidgetsFlutterBinding.ensureInitialized();

  // Measured off the two watches in the device matrix. Using the real numbers
  // rather than round ones keeps these tests honest about the arithmetic that
  // actually ships.
  const double galaxyResolution = 4.774; // units per radian, 60 detents
  const double galaxyScrollPerDetent = 0.5;
  const double pixelResolution = -0.791; // negative, and that is valid

  // Both resolutions are as `dumpsys input` prints them, to three decimals. The
  // Galaxy's exact value is 30/(2*pi) = 4.77465, so a revolution built from the
  // rounded figure lands about 0.0009 rad off 2*pi. Tolerances below are sized
  // for that rounding, not for slack in the arithmetic - the point of the
  // assertions is that one physical turn is one turn, and it is.

  group('proportionality', () {
    // The headline invariant. Rotation reported must depend on how far the
    // control moved and on nothing else - not on how many events carried it,
    // and not on how quickly they arrived.
    //
    // The bug this locks out made the step a flat constant per *event*, so
    // accumulation tracked event count. Event rate is capped by the input
    // pipeline, so a fast turn arrived in fewer events than a slow one over the
    // same arc and steered less. Turning faster did less.
    test('the same rotation accumulates the same however it is split', () {
      for (final double? res in <double?>[null, galaxyResolution]) {
        final double whole = _accumulate(_rotary(), 12.0, 1, res: res);
        final double twelfths = _accumulate(_rotary(), 12.0, 12, res: res);
        final double thirds = _accumulate(_rotary(), 12.0, 3, res: res);

        expect(twelfths, closeTo(whole, 1e-12), reason: 'res: $res');
        expect(thirds, closeTo(whole, 1e-12), reason: 'res: $res');
        expect(whole, isNot(0));
      }
    });

    test('the same rotation accumulates the same however fast it arrives', () {
      // One drain, as if the whole turn landed inside a single frame.
      final Rotary fast = _rotary();
      final double inOneStep = _accumulate(fast, 30.0, 30, res: galaxyResolution);

      // Sixty drains, as if it were spread over a second of frames.
      final Rotary slow = _rotary();
      double total = 0.0;
      for (int step = 0; step < 60; step++) {
        for (int i = 0; i < 30 ~/ 60 + 1; i++) {
          if (step * (30 ~/ 60 + 1) + i >= 30) break;
          slow.debugHandleEvent(
            _event(1.0, resolution: galaxyResolution),
          );
        }
        total += slow.consumeAngleDelta();
      }

      expect(total, closeTo(inOneStep, 1e-12));
    });

    test('a fraction of a scroll unit is a fraction of the angle', () {
      final Rotary rotary = _rotary()..radiansPerScrollUnit = 0.1;
      rotary.debugHandleEvent(_event(0.25));
      expect(rotary.consumeAngleDelta(), closeTo(0.025, 1e-12));
    });

    test('a large single event is not clamped to one tick', () {
      final Rotary rotary = _rotary()..radiansPerScrollUnit = 0.1;
      rotary.debugHandleEvent(_event(10.0));
      expect(rotary.consumeAngleDelta(), closeTo(1.0, 1e-12));
    });
  });

  group('measured hardware', () {
    // Both watches should land on exactly one turn in, one turn out, with no
    // per-device constant. If either of these moves, a calibration assumption
    // has changed and the device matrix needs revisiting.
    test('a Galaxy Watch5 bezel revolution is exactly 2*pi', () {
      final Rotary rotary = _rotary();
      for (int detent = 0; detent < 60; detent++) {
        rotary.debugHandleEvent(
          _event(galaxyScrollPerDetent, resolution: galaxyResolution),
        );
      }
      expect(rotary.consumeAngleDelta(), closeTo(6.283185, 2e-3));
    });

    test('a Pixel Watch 3 crown revolution is exactly 2*pi', () {
      // The crown publishes a *negative* resolution. Scaling by its magnitude
      // is what makes this work; rejecting it - which is what shipped - is what
      // dropped the crown onto the flat fallback.
      final Rotary rotary = _rotary();
      final double perRevolution = 6.283185 * pixelResolution.abs();
      rotary.debugHandleEvent(
        _event(perRevolution, resolution: pixelResolution),
      );
      expect(rotary.consumeAngleDelta(), closeTo(6.283185, 2e-3));
    });

    test('a negative resolution does not reverse the direction', () {
      // Direction lives in the sign of the scroll value. The Galaxy is the
      // reversed device and its resolution is positive, so a resolution's sign
      // cannot be read as a direction convention.
      final Rotary rotary = _rotary();
      rotary.debugHandleEvent(_event(1.0, resolution: pixelResolution));
      expect(rotary.consumeAngleDelta(), greaterThan(0));
    });
  });

  group('path selection', () {
    test('magnitudeScale applies only on the resolution path', () {
      final Rotary withRes = _rotary()..magnitudeScale = 2.0;
      withRes.debugHandleEvent(_event(1.0, resolution: 4.0));
      expect(withRes.consumeAngleDelta(), closeTo(0.5, 1e-12));

      final Rotary without = _rotary()
        ..magnitudeScale = 2.0
        ..radiansPerScrollUnit = 0.1;
      without.debugHandleEvent(_event(1.0));
      expect(without.consumeAngleDelta(), closeTo(0.1, 1e-12));
    });

    test('radiansPerScrollUnit applies only off the resolution path', () {
      final Rotary rotary = _rotary()..radiansPerScrollUnit = 99.0;
      rotary.debugHandleEvent(_event(1.0, resolution: 4.0));
      expect(rotary.consumeAngleDelta(), closeTo(0.25, 1e-12));
    });

    test('resolutionOverride forces the resolution path', () {
      final Rotary rotary = _rotary()
        ..radiansPerScrollUnit = 99.0
        ..resolutionOverride = 4.0;
      rotary.debugHandleEvent(_event(1.0));
      expect(rotary.consumeAngleDelta(), closeTo(0.25, 1e-12));
    });

    test('resolutionOverride beats the value the device published', () {
      final Rotary rotary = _rotary()..resolutionOverride = 4.0;
      rotary.debugHandleEvent(_event(1.0, resolution: 1000.0));
      expect(rotary.consumeAngleDelta(), closeTo(0.25, 1e-12));
    });
  });

  group('direction', () {
    test('invert flips the accumulator and the event together', () async {
      final Rotary plain = _rotary();
      final Rotary flipped = _rotary()..invert = true;

      final List<RotaryEvent> seen = <RotaryEvent>[];
      final StreamSubscription<RotaryEvent> sub = flipped.events.listen(
        seen.add,
      );

      plain.debugHandleEvent(_event(1.0, resolution: 4.0));
      flipped.debugHandleEvent(_event(1.0, resolution: 4.0));

      expect(plain.consumeAngleDelta(), closeTo(0.25, 1e-12));
      expect(flipped.consumeAngleDelta(), closeTo(-0.25, 1e-12));

      // Stream delivery is asynchronous even for a synchronous `add`, so the
      // listener has to be given a turn before it can be asserted on.
      await _drainMicrotasks();
      expect(seen.single.direction, RotaryDirection.counterClockwise);
      expect(seen.single.radians, lessThan(0));

      await sub.cancel();
    });

    test('direction and radians never disagree', () async {
      final Rotary rotary = _rotary();
      final List<RotaryEvent> seen = <RotaryEvent>[];
      final StreamSubscription<RotaryEvent> sub = rotary.events.listen(seen.add);

      const List<double> scrolls = <double>[1.0, -1.0, 0.25, -8.0];
      for (final double scroll in scrolls) {
        rotary.debugHandleEvent(_event(scroll, resolution: 4.0));
      }
      await _drainMicrotasks();

      // Asserted before the loop: an empty list would satisfy every check
      // inside it, and a silently vacuous test is worse than no test.
      expect(seen, hasLength(scrolls.length));
      for (final RotaryEvent e in seen) {
        expect(
          e.direction == RotaryDirection.clockwise,
          e.radians > 0,
          reason: '$e',
        );
      }
      await sub.cancel();
    });
  });

  group('deprecated tickAngle', () {
    test('is a true alias for radiansPerScrollUnit in both directions', () {
      final Rotary rotary = _rotary();
      // ignore: deprecated_member_use_from_same_package
      rotary.tickAngle = 0.5;
      expect(rotary.radiansPerScrollUnit, 0.5);

      rotary.radiansPerScrollUnit = 0.25;
      // ignore: deprecated_member_use_from_same_package
      expect(rotary.tickAngle, 0.25);
    });
  });

  group('robustness', () {
    test('junk payloads are ignored without throwing', () {
      final Rotary rotary = _rotary();
      for (final dynamic raw in <dynamic>[
        null,
        'not a map',
        42,
        <String, Object>{},
        <String, Object>{'scroll': 0.0},
        <String, Object>{'scroll': double.nan},
        <String, Object>{'scroll': double.infinity},
        <String, Object>{'scroll': 'sideways'},
      ]) {
        expect(() => rotary.debugHandleEvent(raw), returnsNormally);
      }
      expect(rotary.consumeAngleDelta(), 0.0);
    });

    test('a non-finite resolution falls back to the scroll-unit path', () {
      final Rotary rotary = _rotary()..radiansPerScrollUnit = 0.1;
      rotary.debugHandleEvent(_event(1.0, resolution: double.nan));
      rotary.debugHandleEvent(_event(1.0, resolution: double.infinity));
      expect(rotary.consumeAngleDelta(), closeTo(0.2, 1e-12));
    });

    test('a zero resolution falls back rather than dividing by zero', () {
      final Rotary rotary = _rotary()..radiansPerScrollUnit = 0.1;
      rotary.debugHandleEvent(_event(1.0, resolution: 0.0));
      final double delta = rotary.consumeAngleDelta();
      expect(delta.isFinite, isTrue);
      expect(delta, closeTo(0.1, 1e-12));
    });
  });

  group('accumulator', () {
    test('draining empties it and it refills from there', () {
      final Rotary rotary = _rotary()..radiansPerScrollUnit = 0.1;
      rotary.debugHandleEvent(_event(1.0));
      expect(rotary.consumeAngleDelta(), closeTo(0.1, 1e-12));
      expect(rotary.consumeAngleDelta(), 0.0);
      rotary.debugHandleEvent(_event(2.0));
      expect(rotary.consumeAngleDelta(), closeTo(0.2, 1e-12));
    });

    test('dispose clears what was banked', () async {
      final Rotary rotary = _rotary()..radiansPerScrollUnit = 0.1;
      rotary.debugHandleEvent(_event(1.0));
      await rotary.dispose();
      expect(rotary.consumeAngleDelta(), 0.0);
    });
  });

  group('diagnostics', () {
    test('count events, samples and raw scroll', () {
      final Rotary rotary = _rotary();
      rotary.debugHandleEvent(
        _event(
          0.5,
          resolution: galaxyResolution,
          samples: 3,
          scrollFactor: 64.0,
          deviceName: 'detent_bezel',
        ),
      );
      rotary.debugHandleEvent(_event(-2.0, resolution: galaxyResolution));

      final RotaryDiagnostics d = rotary.diagnostics;
      expect(d.events, 2);
      expect(d.samples, 4);
      expect(d.maxHistorySamples, 3);
      expect(d.rawScrollTotal, closeTo(-1.5, 1e-12));
      expect(d.lastScroll, closeTo(-2.0, 1e-12));
      expect(d.maxAbsScrollPerEvent, closeTo(2.0, 1e-12));
      expect(d.resolution, galaxyResolution);
      expect(d.scrollFactor, 64.0);
      expect(d.deviceName, 'detent_bezel');
      expect(d.deviceId, 8);
    });

    test('the reported resolution keeps its sign, unlike the scaling', () {
      // The scaling takes the magnitude, but the diagnostic must show what the
      // device actually said - that negative value is the whole reason the
      // crown was mishandled, and hiding it would hide the next such bug.
      final Rotary rotary = _rotary();
      rotary.debugHandleEvent(_event(1.0, resolution: pixelResolution));
      expect(rotary.diagnostics.resolution, pixelResolution);
      expect(rotary.diagnostics.radiansTotal, greaterThan(0));
    });

    test('resetDiagnostics clears counts but keeps the hardware identity', () {
      final Rotary rotary = _rotary();
      rotary.debugHandleEvent(
        _event(
          1.0,
          resolution: galaxyResolution,
          deviceName: 'detent_bezel',
          scrollFactor: 64.0,
        ),
      );
      rotary.resetDiagnostics();

      final RotaryDiagnostics d = rotary.diagnostics;
      expect(d.events, 0);
      expect(d.rawScrollTotal, 0.0);
      expect(d.radiansTotal, 0.0);
      expect(d.sinceReset, Duration.zero);
      // Describes the hardware, not the run - blanking it would leave the
      // readout empty until the next event for no gain.
      expect(d.resolution, galaxyResolution);
      expect(d.deviceName, 'detent_bezel');
      expect(d.scrollFactor, 64.0);
    });

    test('the elapsed span stops with the turning', () {
      // Read off a watch face and written down by hand, so a figure that keeps
      // climbing after the bezel stops is a figure that is wrong by the time it
      // has been read.
      final Rotary rotary = _rotary();
      rotary.debugHandleEvent(
        _event(1.0, resolution: galaxyResolution, eventTimeMs: 0),
      );
      rotary.debugHandleEvent(
        _event(1.0, resolution: galaxyResolution, eventTimeMs: 500),
      );
      final Duration first = rotary.diagnostics.sinceReset;
      final Duration second = rotary.diagnostics.sinceReset;
      expect(second, first);
    });

    test('scrollPerRevolution is independent of every scaling knob', () {
      // Which is what makes it the number to calibrate against, and the one to
      // compare between a slow turn and a fast one.
      final Rotary a = _rotary()..magnitudeScale = 1.0;
      final Rotary b = _rotary()..magnitudeScale = 7.0;
      for (final Rotary r in <Rotary>[a, b]) {
        for (int i = 0; i < 60; i++) {
          r.debugHandleEvent(
            _event(galaxyScrollPerDetent, resolution: galaxyResolution),
          );
        }
      }
      expect(
        a.diagnostics.scrollPerRevolution(1),
        b.diagnostics.scrollPerRevolution(1),
      );
      expect(a.diagnostics.scrollPerRevolution(1), closeTo(30.0, 1e-12));
      expect(a.diagnostics.radiansPerRevolution(1), closeTo(6.283185, 2e-3));
    });
  });

  group('platform wiring', () {
    // Everything above drives the seam directly. This one proves the seam is
    // fed by the real channel, so a payload key renamed on the native side
    // cannot pass the rest of the suite.
    const String channel = 'sizzle_wearable/rotary';

    test('events arrive through the event channel', () async {
      final Rotary rotary = Rotary(const EventChannel(channel))
        ..radiansPerScrollUnit = 0.1;

      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockStreamHandler(
            const EventChannel(channel),
            _StubStream(<Object>[
              _event(2.0, resolution: 4.0, deviceName: 'crown'),
            ]),
          );

      final List<RotaryEvent> seen = <RotaryEvent>[];
      final StreamSubscription<RotaryEvent> sub = rotary.events.listen(seen.add);
      // The payload crosses the mock messenger, so a microtask is not enough -
      // it has to go out through the codec and come back.
      await _drainMicrotasks();
      await _drainMicrotasks();

      expect(seen, hasLength(1));
      expect(seen.single.scroll, 2.0);
      expect(seen.single.radians, closeTo(0.5, 1e-12));
      expect(seen.single.deviceRadians, closeTo(0.5, 1e-12));
      expect(rotary.consumeAngleDelta(), closeTo(0.5, 1e-12));
      expect(rotary.diagnostics.deviceName, 'crown');

      await sub.cancel();
    });
  });
}

/// Replays a fixed list of payloads as if the platform had sent them.
class _StubStream extends MockStreamHandler {
  const _StubStream(this.payloads);

  final List<Object> payloads;

  @override
  void onListen(Object? arguments, MockStreamHandlerEventSink events) {
    for (final Object payload in payloads) {
      events.success(payload);
    }
  }

  @override
  void onCancel(Object? arguments) {}
}
