import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which way the bezel or crown was turned.
enum RotaryDirection {
  /// Clockwise, which conventionally means "forward", "down" or "increase".
  clockwise,

  /// Anticlockwise, the reverse of [clockwise].
  counterClockwise,
}

/// One motion event's worth of rotary input from a rotating bezel (Galaxy
/// Watch) or a rotating crown (Pixel Watch).
class RotaryEvent {
  const RotaryEvent({
    required this.direction,
    required this.radians,
    required this.scroll,
    this.deviceRadians,
  });

  /// Which way the input was turned.
  final RotaryDirection direction;

  /// How far it was turned, in radians, signed the same way the accumulator
  /// counts it: positive is clockwise.
  ///
  /// Exactly what [Rotary.consumeAngleDelta] added for this event, so a
  /// listener and the accumulator can never disagree about what arrived.
  final double radians;

  /// The device's own raw `AXIS_SCROLL` value, signed, before any scaling.
  ///
  /// The number to calibrate against: it is the only figure here unaffected by
  /// [Rotary.magnitudeScale], [Rotary.radiansPerScrollUnit] and
  /// [Rotary.resolutionOverride], so it stays comparable while those are tuned.
  final double scroll;

  /// Radians as the device's own published resolution defines them, before
  /// [Rotary.magnitudeScale]. Null when the device publishes no usable
  /// resolution and the raw scroll units are all there is.
  final double? deviceRadians;

  /// How far it was turned, in radians, always positive.
  @Deprecated('Use radians, which is signed and never null')
  double? get magnitude => radians.abs();

  @override
  String toString() =>
      'RotaryEvent($direction, radians: $radians, scroll: $scroll, '
      'deviceRadians: $deviceRadians)';
}

/// A snapshot of what the rotary hardware has actually been reporting.
///
/// Exists because rotary behaviour cannot be reasoned about from a spec sheet.
/// Whether a device publishes a scroll resolution, how large a raw scroll unit
/// is, how many events a second it emits and whether it batches them are all
/// per-device and per-OS-build, they are all invisible from Dart without
/// measuring, and every one of them changes how the input should be scaled.
///
/// Collected unconditionally rather than behind a debug flag: the numbers are
/// wanted from whatever build happens to be on the watch when something feels
/// wrong, and needing a special build to reproduce an input problem is how
/// input problems survive.
@immutable
class RotaryDiagnostics {
  const RotaryDiagnostics({
    required this.events,
    required this.samples,
    required this.maxHistorySamples,
    required this.rawScrollTotal,
    required this.radiansTotal,
    required this.lastScroll,
    required this.maxAbsScrollPerEvent,
    required this.resolution,
    required this.scrollFactor,
    required this.deviceId,
    required this.deviceName,
    required this.eventsPerSecond,
    required this.peakRadiansPerSecond,
    required this.sinceReset,
  });

  /// Platform events seen since the last reset.
  final int events;

  /// Motion samples those events carried, counting batched history.
  ///
  /// Equal to [events] when nothing is batching. Larger means the platform is
  /// coalescing, which is only harmless if the history is being summed.
  final int samples;

  /// The largest `1 + historySize` any single event carried.
  ///
  /// `1` means no batching has ever been observed on this device.
  final int maxHistorySamples;

  /// Signed sum of raw `AXIS_SCROLL` units. The device's own numbers, before
  /// any interpretation - this is the value to calibrate against.
  final double rawScrollTotal;

  /// Signed sum of radians as the accumulator understood them.
  final double radiansTotal;

  /// Raw scroll on the most recent event.
  final double lastScroll;

  /// The largest single-event raw scroll magnitude seen.
  ///
  /// Tells you the size of a scroll unit: a device reporting `1.0` per detent
  /// and one reporting `0.02` per sample need very different scaling, and this
  /// is the only way to tell them apart.
  final double maxAbsScrollPerEvent;

  /// Scroll units per radian as the device reports them, or null when it
  /// publishes none - in which case the raw scroll units are all there is.
  final double? resolution;

  /// `ViewConfiguration.getScaledVerticalScrollFactor`. Pixels of list scroll
  /// per scroll unit; no angular meaning. Recorded for comparison only.
  final double? scrollFactor;

  /// Android input device id of the most recent event's source.
  final int? deviceId;

  /// Android input device name of the most recent event's source.
  final String? deviceName;

  /// Events per second over roughly the last second.
  ///
  /// A number that stops rising as the input is turned faster means the
  /// pipeline is saturating, and rotation is being lost rather than reported.
  final double eventsPerSecond;

  /// The highest windowed angular rate seen since the reset.
  ///
  /// For a rate-controlled input this is the number that decides whether a
  /// control is reachable at all: if the fastest a player can physically move
  /// the bezel falls short of what full deflection demands, no amount of
  /// calibrating radians-per-revolution will fix the feel.
  final double peakRadiansPerSecond;

  /// Time from the reset to the most recent event.
  ///
  /// Deliberately not "time since the reset": it stops when the turning stops,
  /// so it can be read off a watch face and written down.
  final Duration sinceReset;

  /// Radians per full physical revolution, given [revolutions] actually turned.
  ///
  /// The calibration target: this should come out at 2*pi. Returns null when
  /// nothing has been turned yet.
  double? radiansPerRevolution(double revolutions) =>
      revolutions == 0 ? null : radiansTotal.abs() / revolutions;

  /// Raw scroll units per full physical revolution, given [revolutions] turned.
  ///
  /// Independent of every knob in this class, so it is the measurement that
  /// stays valid across scaling changes - and comparing it between a slow turn
  /// and a fast one is the direct test for whether the platform is dropping
  /// rotation under speed.
  double? scrollPerRevolution(double revolutions) =>
      revolutions == 0 ? null : rawScrollTotal.abs() / revolutions;

  @override
  String toString() =>
      'RotaryDiagnostics(events: $events, samples: $samples, '
      'maxHistorySamples: $maxHistorySamples, rawScrollTotal: $rawScrollTotal, '
      'radiansTotal: $radiansTotal, lastScroll: $lastScroll, '
      'maxAbsScrollPerEvent: $maxAbsScrollPerEvent, resolution: $resolution, '
      'scrollFactor: $scrollFactor, deviceId: $deviceId, '
      'deviceName: $deviceName, eventsPerSecond: $eventsPerSecond, '
      'peakRadiansPerSecond: $peakRadiansPerSecond, sinceReset: $sinceReset)';
}

/// Rotary input from the watch bezel or crown.
///
/// Two ways to consume it, and which you want depends on the shape of your
/// code:
///
/// * [events] is a plain broadcast stream, for UI-style code that reacts to
///   each detent.
/// * [consumeAngleDelta] is an accumulator, for game code. Rotation piles up
///   as it arrives and you drain the total once per simulation step. This is
///   the right choice inside a `Scene.fixedUpdate`, because it keeps input
///   sampling at the simulation rate no matter how often the game paints -
///   including in the half-rate `FrameRateMode`s.
///
/// ```dart
/// @override
/// void fixedUpdate(double fixedDt) {
///   turret.angle += SizzleWearable.rotary.consumeAngleDelta();
/// }
/// ```
///
/// Off Wear OS (desktop during development, a phone build, the simulator)
/// there is simply no rotary hardware: [events] never emits and
/// [consumeAngleDelta] always returns `0`. No platform checks needed at the
/// call site.
class Rotary {
  /// @nodoc
  Rotary(EventChannel channel) : _channel = channel;

  final EventChannel _channel;

  StreamController<RotaryEvent>? _controller;
  StreamSubscription<dynamic>? _subscription;

  /// Radians applied per **unit of raw scroll** on devices that publish no
  /// usable `AXIS_SCROLL` resolution.
  ///
  /// Per scroll unit, *not* per event. Those are the same thing only on
  /// hardware that reports exactly one unit per detent, and treating them as
  /// interchangeable is a bug with a distinctive signature: rotation ends up
  /// proportional to how long the control was moved rather than how far, so
  /// turning faster does *less*. Neither watch measured so far takes this path
  /// at all - it is the fallback for hardware that publishes nothing.
  double radiansPerScrollUnit = 0.1;

  /// Radians applied per unit of raw scroll.
  @Deprecated(
    'Renamed to radiansPerScrollUnit; it was never per-event. The default '
    'value and the behaviour on one-unit-per-detent hardware are unchanged.',
  )
  double get tickAngle => radiansPerScrollUnit;

  @Deprecated('Renamed to radiansPerScrollUnit; it was never per-event.')
  set tickAngle(double value) => radiansPerScrollUnit = value;

  /// Multiplier applied to the radians the device's own resolution defines.
  ///
  /// `1.0` tracks the hardware exactly: one full turn of the bezel or crown is
  /// one full turn in game. Lower it to damp a twitchy control, raise it to
  /// amplify a stiff one.
  ///
  /// Measured at `1.0`, one physical revolution comes out at 2*pi radians on
  /// **both** a Galaxy Watch5 touch bezel (60 detents, `resolution` 4.774, 0.5
  /// scroll units per detent) and a Pixel Watch 3 crown (`resolution` -0.791,
  /// about 4.97 scroll units per revolution). So `1.0` is both the principled
  /// value and the measured one, and a game wanting the two to feel alike does
  /// not need a per-device constant here.
  ///
  /// An earlier note recorded the Watch5 needing `0.8`. That was a Wear OS 3
  /// scroll-resolution quirk which its own OS update removed, and it is the
  /// reason this is a knob rather than a constant: sensitivity is per-OS-build,
  /// so never calibrate it against a single one.
  double magnitudeScale = 1.0;

  /// Overrides the device's published scroll resolution, in units per radian.
  ///
  /// Two jobs, because they want the same escape hatch: it replaces a
  /// resolution the device publishes but gets wrong, and it supplies one for a
  /// device that publishes none - forcing that device onto the resolution path
  /// instead of [radiansPerScrollUnit].
  ///
  /// Only the magnitude is used - the sign of a resolution is not direction
  /// information, however much it looks like it.
  double? resolutionOverride;

  /// Reverses the reported direction.
  ///
  /// Rotary input is supposed to be transparent across crowns, physical
  /// bezels and touch bezels, but the sign is not consistent in practice: a
  /// clockwise finger movement on a Galaxy Watch5 touch bezel arrives with
  /// the opposite sign to a clockwise turn of a Pixel Watch 3 crown. There is
  /// no way to detect which convention a device uses, so this is exposed as a
  /// knob rather than guessed at.
  ///
  /// Affects both [consumeAngleDelta] and the [RotaryEvent.direction] on
  /// [events], so the two never disagree.
  bool invert = false;

  double _accumulated = 0.0;

  /// Every rotary detent, as it arrives.
  ///
  /// A broadcast stream, so several listeners can share it. Listening also
  /// starts the accumulator feeding [consumeAngleDelta].
  Stream<RotaryEvent> get events {
    final controller = _controller ??= StreamController<RotaryEvent>.broadcast(
      onListen: _start,
    );
    return controller.stream;
  }

  /// Total rotation in radians since this was last called, then resets to
  /// zero.
  ///
  /// Positive is clockwise. Because the value accumulates between calls, the
  /// total rotation reported over any span of time is the same regardless of
  /// how often you drain it - calling it at 30Hz and at 60Hz both integrate
  /// to the same angle.
  double consumeAngleDelta() {
    _start();
    final delta = _accumulated;
    _accumulated = 0.0;
    return delta;
  }

  /// Begins listening to the platform, if not already. Safe to call often.
  void _start() {
    if (_subscription != null) return;
    try {
      _subscription = _channel.receiveBroadcastStream().listen(
            _onPlatformEvent,
            // A watch that stops reporting is not an error worth crashing over.
            onError: (Object _) {},
          );
    } on MissingPluginException {
      // Not a Wear OS build. Leave the stream silent and the accumulator at
      // zero rather than making every caller guard.
    }
  }

  /// Feed a platform payload straight in, as if it had arrived from the
  /// channel.
  ///
  /// The seam that lets the accumulator be tested synchronously, with no
  /// binding and no mock channel - which matters because the properties worth
  /// asserting here are about how a *sequence* of events accumulates.
  @visibleForTesting
  void debugHandleEvent(dynamic raw) => _onPlatformEvent(raw);

  /// Reads a channel field without trusting its type.
  ///
  /// A cast would throw on the wrong type, and this runs on the platform
  /// stream where nothing catches - one malformed payload would take down
  /// input for the session. Read defensively even though the sender is our own
  /// plugin: it is a different language on the other side of a dynamic map.
  static double? _asDouble(Object? v) => v is num ? v.toDouble() : null;
  static int? _asInt(Object? v) => v is num ? v.toInt() : null;

  void _onPlatformEvent(dynamic raw) {
    if (raw is! Map) return;
    var scroll = _asDouble(raw['scroll']);
    // A non-finite scroll would poison the accumulator permanently - there is
    // no recovery from a NaN total short of `dispose` - so it is rejected here
    // rather than trusted because it came from our own plugin.
    if (scroll == null || scroll == 0 || !scroll.isFinite) return;
    if (invert) scroll = -scroll;

    final direction = scroll > 0
        ? RotaryDirection.clockwise
        : RotaryDirection.counterClockwise;

    double? resolution = _asDouble(raw['resolution']);
    if (resolution != null && !resolution.isFinite) resolution = null;

    final double? deviceRadians = _deviceRadians(scroll, resolution);
    final double radians = deviceRadians != null
        ? deviceRadians * magnitudeScale
        : scroll * radiansPerScrollUnit;
    _accumulated += radians;

    _record(raw, scroll, radians, resolution);

    _controller?.add(
      RotaryEvent(
        direction: direction,
        radians: radians,
        scroll: scroll,
        deviceRadians: deviceRadians,
      ),
    );
  }

  /// Radians as the device's own resolution defines them, or null when it
  /// publishes nothing usable.
  ///
  /// **Scaled by the magnitude of the resolution, never its sign.** A negative
  /// resolution is real - a Pixel Watch 3 crown publishes `-0.791` - and it is
  /// tempting to read the sign as the device declaring its direction
  /// convention. The measurements rule that out: the Galaxy Watch5 is the
  /// reversed device and its resolution is *positive*. So direction lives in
  /// the sign of the scroll value, and [invert] remains the knob for it.
  ///
  /// Rejecting that negative resolution rather than taking its magnitude is
  /// what put the crown on the flat per-event fallback and made its steering
  /// track duration instead of distance.
  double? _deviceRadians(double scroll, double? resolution) {
    final double? res = resolutionOverride ?? resolution;
    if (res == null || !res.isFinite || res == 0) return null;
    return scroll / res.abs();
  }

  // ------------------------------------------------------------ diagnostics

  final Stopwatch _since = Stopwatch();
  int _events = 0;
  int _samples = 0;
  int _maxHistorySamples = 0;
  double _rawScrollTotal = 0.0;
  double _radiansTotal = 0.0;
  double _lastScroll = 0.0;
  double _maxAbsScroll = 0.0;
  double? _resolution;
  double? _scrollFactor;
  int? _deviceId;
  String? _deviceName;
  double _peakRadiansPerSecond = 0.0;

  /// When the last event landed, so the reported span covers the *measurement*
  /// rather than the wall clock.
  ///
  /// A figure still climbing after the bezel has stopped cannot be written down
  /// - by the time you have read it, it is wrong - and the number wanted is how
  /// long the turn took, not how long ago it was.
  Duration _lastEventElapsed = Duration.zero;

  /// Event times and radians inside the rate window, oldest first.
  final List<double> _windowMs = <double>[];
  final List<double> _windowRadians = <double>[];

  /// How far back the events-per-second and rate figures look.
  static const double _rateWindowMs = 1000.0;

  /// Below this the window is too short to divide by without inventing a
  /// number: two events 3ms apart are not evidence of 300 events a second.
  static const double _minRateWindowMs = 150.0;

  void _record(
    Map<dynamic, dynamic> raw,
    double signedScroll,
    double radians,
    double? resolution,
  ) {
    if (!_since.isRunning) _since.start();

    _events++;
    final int samples = _asInt(raw['samples']) ?? 1;
    _samples += samples;
    _maxHistorySamples = math.max(_maxHistorySamples, samples);
    _rawScrollTotal += signedScroll;
    _radiansTotal += radians;
    _lastScroll = signedScroll;
    _maxAbsScroll = math.max(_maxAbsScroll, signedScroll.abs());
    _resolution = resolution ?? _resolution;
    _scrollFactor = _asDouble(raw['scrollFactor']) ?? _scrollFactor;
    _lastEventElapsed = _since.elapsed;
    _deviceId = _asInt(raw['deviceId']) ?? _deviceId;
    final Object? name = raw['deviceName'];
    if (name is String) _deviceName = name;

    // The platform's own event time where there is one. It is a monotonic
    // uptime clock, so it survives the wall clock moving and it measures the
    // input pipeline rather than how promptly Dart got scheduled - which is
    // the distinction that matters when the question is whether events are
    // being dropped.
    final double nowMs =
        _asDouble(raw['eventTimeMs']) ??
        _since.elapsedMicroseconds / 1000.0;
    _windowMs.add(nowMs);
    _windowRadians.add(radians);
    while (_windowMs.length > 1 && nowMs - _windowMs.first > _rateWindowMs) {
      _windowMs.removeAt(0);
      _windowRadians.removeAt(0);
    }
    final double spanMs = nowMs - _windowMs.first;
    if (spanMs >= _minRateWindowMs) {
      double sum = 0.0;
      for (final double r in _windowRadians) {
        sum += r.abs();
      }
      _peakRadiansPerSecond = math.max(
        _peakRadiansPerSecond,
        sum / (spanMs / 1000.0),
      );
    }
  }

  /// What the hardware has reported since the last [resetDiagnostics].
  RotaryDiagnostics get diagnostics {
    final double spanMs = _windowMs.length < 2
        ? 0.0
        : _windowMs.last - _windowMs.first;
    return RotaryDiagnostics(
      events: _events,
      samples: _samples,
      maxHistorySamples: _maxHistorySamples,
      rawScrollTotal: _rawScrollTotal,
      radiansTotal: _radiansTotal,
      lastScroll: _lastScroll,
      maxAbsScrollPerEvent: _maxAbsScroll,
      resolution: _resolution,
      scrollFactor: _scrollFactor,
      deviceId: _deviceId,
      deviceName: _deviceName,
      eventsPerSecond: spanMs >= _minRateWindowMs
          ? _windowMs.length / (spanMs / 1000.0)
          : 0.0,
      peakRadiansPerSecond: _peakRadiansPerSecond,
      sinceReset: _lastEventElapsed,
    );
  }

  /// Zero the counters and start a fresh measurement.
  ///
  /// Deliberately leaves [resolution], [scrollFactor] and the device identity
  /// alone: they describe the hardware rather than the run, and clearing them
  /// would blank the display until the next event for no gain.
  void resetDiagnostics() {
    _since
      ..reset()
      ..stop();
    _events = 0;
    _samples = 0;
    _maxHistorySamples = 0;
    _rawScrollTotal = 0.0;
    _radiansTotal = 0.0;
    _lastScroll = 0.0;
    _maxAbsScroll = 0.0;
    _peakRadiansPerSecond = 0.0;
    _lastEventElapsed = Duration.zero;
    _windowMs.clear();
    _windowRadians.clear();
  }

  /// Stops listening and discards any unconsumed rotation.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.close();
    _controller = null;
    _accumulated = 0.0;
  }
}
