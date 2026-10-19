import 'dart:math';

import 'package:flutter/painting.dart';
// Sizzle re-exports only `runApp` from widgets, and a blanket widgets import
// would make `TextStyle` ambiguous against Flame's own.
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:sizzle/sizzle.dart';
import 'package:sizzle_wearable/sizzle_wearable.dart';

/// Minimal Wear OS demo for `sizzle_wearable`.
///
/// Two screens, both driven by tap and long press only - a round watch has no
/// room for anything else:
///
///  * [DemoScene] - a dial driven by the bezel or crown, plus a live readout of
///    the render and simulation clocks. Tap cycles frame rate modes: the render
///    rate should halve while the simulation rate and the dial's responsiveness
///    do not. Long press opens the rotary calibration.
///  * [RotaryScene] - measures what the rotary hardware actually reports. See
///    its own doc comment for the protocol.
///
/// Runs on desktop too - rotary simply reports nothing there, which is the
/// point of the no-op fallbacks.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SizzleWearable.attach();

  // Watches dim within seconds; keep the panel up while the demo is running.
  await SizzleWearable.display.setKeepScreenOn(true);
  // A round watch has a lot of "edge", so keep system gestures out of it.
  await SizzleWearable.display.setGestureExclusionEnabled(true);

  runApp(
    GameWidget(
      game: SizzleGame(
        scenes: {'demo': DemoScene.new, 'rotary': RotaryScene.new},
        targetSize: Vector2(192, 192),
        fixedUpdateFps: 60,
        measureFps: true,
      ),
    ),
  );
}

/// The inscribed square of a 192-unit round face, with a little margin.
///
/// Anything outside this is clipped by the bezel on a round watch, and a
/// readout you have to tilt the watch to finish reading is a readout you will
/// misreport.
const double _safe = 65.0;
const double _centre = 96.0;

const Color _ink = Color(0xff00ff88);
const Color _dim = Color(0xff5a8f74);

TextPaint _text(Color colour) => TextPaint(
  style: TextStyle(
    color: colour,
    fontSize: 9,
    // Columns that do not move between frames. Without this the numbers jitter
    // sideways as digits change and become genuinely hard to read on a watch.
    fontFamily: 'monospace',
    height: 1.25,
  ),
);

class DemoScene extends Scene {
  static const _modes = FrameRateMode.values;

  final _readout = TextComponent(
    position: Vector2(_centre, 118),
    anchor: Anchor.topCenter,
    textRenderer: TextPaint(
      style: const TextStyle(color: Color(0xffffffff), fontSize: 9),
    ),
  );

  final _needle = RectangleComponent(
    size: Vector2(3, 56),
    anchor: Anchor.bottomCenter,
    paint: Paint()..color = const Color(0xff4fc3f7),
  );

  int _modeIndex = 0;
  double _angle = 0.0;
  bool _isRound = false;

  @override
  Future<void> onLoad() async {
    _isRound = await SizzleWearable.display.isRound;

    _needle.position = Vector2(_centre, _centre);
    add(_needle);
    add(_readout);
    add(
      TouchArea(
        size: game.targetGameSize,
        onTap: _cycleMode,
        onLongPress: () => changeScene('rotary'),
      ),
    );
  }

  /// Simulation. Draining the rotary accumulator here rather than in [update]
  /// keeps input sampled at 60Hz even when the game is only painting at 30.
  @override
  void fixedUpdate(double fixedDt) {
    _angle += SizzleWearable.rotary.consumeAngleDelta();
    _needle.angle = _angle % (2 * pi);
  }

  @override
  void update(double dt) {
    super.update(dt);
    _readout.text =
        '${game.effectiveFrameRateMode.name}\n'
        'render ${game.measuredRenderFps.toStringAsFixed(0)}\n'
        'fixed  ${game.measuredFixedUpdateFps.toStringAsFixed(0)}\n'
        '${SizzleWearable.isSupported ? (_isRound ? 'round' : 'square') : 'not wear'}\n'
        'hold: rotary';
  }

  Future<void> _cycleMode() async {
    _modeIndex = (_modeIndex + 1) % _modes.length;
    await game.setFrameRateMode(_modes[_modeIndex]);
  }
}

/// Which of [RotaryScene]'s panels is up.
enum _RotaryMode {
  /// A needle at the accumulated angle against a fixed reference tick, so 1:1
  /// tracking is *seen* rather than computed.
  dial,

  /// What the device says about itself and how fast it is talking.
  stats,

  /// The totals a calibration constant is worked out from.
  cal,

  /// Not a panel - the fourth tap leaves.
  exit,
}

/// Measures what the rotary hardware actually reports.
///
/// Rotary sensitivity cannot be reasoned about from a spec sheet: whether a
/// device publishes a scroll resolution, how large a raw scroll unit is and how
/// many events a second it emits are all per-device *and* per-OS-build. This
/// screen exists so those numbers come from the watch rather than from a guess.
///
/// It reads the accumulator directly, with no game physics in between, which is
/// the whole point - measuring through a steering model means measuring two
/// unknowns at once.
///
/// **Protocol.** Long press to reset, then in `cal`:
///
///  1. *Slow* - one revolution over about four seconds.
///  2. *Fast* - one revolution over about three quarters of a second.
///  3. *Sustained* - five revolutions at a comfortable continuous speed.
///
/// `Sraw` per revolution should come out the same in 1 and 2. If the fast run
/// is materially lower, the platform is dropping rotation under speed and no
/// amount of scaling will fix it. Run 3's `peak` is the fastest a hand can
/// actually drive this device, which is what decides whether a rate-controlled
/// input is reachable at all.
class RotaryScene extends Scene {
  final _title = TextComponent(
    position: Vector2(_centre, _centre - _safe),
    anchor: Anchor.topCenter,
    textRenderer: _text(_dim),
  );

  final _body = TextComponent(
    position: Vector2(_centre - _safe, _centre - _safe + 16),
    anchor: Anchor.topLeft,
    textRenderer: _text(_ink),
  );

  final _needle = RectangleComponent(
    size: Vector2(3, 52),
    anchor: Anchor.bottomCenter,
    paint: Paint()..color = _ink,
  );

  /// Fixed at twelve o'clock. The needle is only readable against something
  /// that does not move.
  final _reference = RectangleComponent(
    size: Vector2(2, 12),
    anchor: Anchor.bottomCenter,
    paint: Paint()..color = _dim,
  );

  _RotaryMode _mode = _RotaryMode.dial;
  double _angle = 0.0;

  /// Held so the readout stops changing when the hardware does, rather than
  /// showing whatever the last frame's `deviceInfo` future resolved to.
  Map<String, dynamic>? _hardware;

  @override
  Future<void> onLoad() async {
    _needle.position = Vector2(_centre, _centre);
    _reference.position = Vector2(_centre, _centre - 40);
    add(_reference);
    add(_needle);
    add(_title);
    add(_body);
    add(
      TouchArea(
        size: game.targetGameSize,
        onTap: _cycleMode,
        onLongPress: _reset,
      ),
    );
    _hardware = await SizzleWearable.rotaryDiagnostics;
  }

  /// Scenes are reused, so the pose the exit left behind has to be undone -
  /// without this, coming back lands on `exit` and shows a blank panel.
  @override
  void onMount() {
    super.onMount();
    _mode = _RotaryMode.dial;
    _reset();
  }

  /// Drained here, at the simulation rate, for the same reason a game would.
  @override
  void fixedUpdate(double fixedDt) {
    _angle += SizzleWearable.rotary.consumeAngleDelta();
    _needle.angle = _angle % (2 * pi);
  }

  @override
  void update(double dt) {
    super.update(dt);
    final RotaryDiagnostics d = SizzleWearable.rotary.diagnostics;
    _title.text = '${_mode.name.toUpperCase()}  (hold=reset)';
    _needle.opacity = _mode == _RotaryMode.dial ? 1 : 0;
    _reference.opacity = _needle.opacity;
    _body.text = switch (_mode) {
      _RotaryMode.dial => '',
      _RotaryMode.stats => _stats(d),
      _RotaryMode.cal => _cal(d),
      _RotaryMode.exit => '',
    };
  }

  String _stats(RotaryDiagnostics d) {
    final String name = d.deviceName ?? _firstHardwareName() ?? '-';
    return '${name.length > 16 ? name.substring(0, 16) : name}\n'
        'id   ${d.deviceId ?? '-'}\n'
        'res  ${d.resolution?.toStringAsFixed(4) ?? 'NONE'}\n'
        'fac  ${d.scrollFactor?.toStringAsFixed(1) ?? '-'}\n'
        'raw  ${d.lastScroll.toStringAsFixed(3)}\n'
        'max  ${d.maxAbsScrollPerEvent.toStringAsFixed(3)}\n'
        'ev/s ${d.eventsPerSecond.toStringAsFixed(1)}\n'
        'hist ${d.maxHistorySamples}';
  }

  String _cal(RotaryDiagnostics d) {
    // Both suggested constants assume exactly one revolution was turned, which
    // is what the protocol asks for. Turn five and divide by five.
    final double twoPi = 2 * pi;
    final String k = d.rawScrollTotal == 0
        ? '-'
        : (twoPi / d.rawScrollTotal.abs()).toStringAsFixed(4);
    final String m = d.radiansTotal == 0
        ? '-'
        : (twoPi / d.radiansTotal.abs()).toStringAsFixed(4);
    return 'Sraw ${d.rawScrollTotal.toStringAsFixed(2)}\n'
        'Srad ${d.radiansTotal.toStringAsFixed(3)}\n'
        'rev  ${(d.radiansTotal.abs() / twoPi).toStringAsFixed(3)}\n'
        'k    $k\n'
        'x    $m\n'
        'peak ${d.peakRadiansPerSecond.toStringAsFixed(1)}\n'
        't    ${(d.sinceReset.inMilliseconds / 1000).toStringAsFixed(1)}s\n'
        'ev   ${d.events}';
  }

  /// The name from `rotaryDiagnostics`, so the panel says something useful
  /// before the first event has arrived.
  String? _firstHardwareName() {
    final Object? devices = _hardware?['devices'];
    if (devices is! List || devices.isEmpty) return null;
    final Object? first = devices.first;
    return first is Map ? first['name'] as String? : null;
  }

  void _cycleMode() {
    _mode = _RotaryMode.values[(_mode.index + 1) % _RotaryMode.values.length];
    if (_mode == _RotaryMode.exit) changeScene('demo');
  }

  void _reset() {
    SizzleWearable.rotary.resetDiagnostics();
    _angle = 0.0;
  }
}

/// Tap and long press over the whole screen.
///
/// Flame delivers `onLongTapDown` *and* the eventual `onTapUp`, so a long press
/// would otherwise fire both actions. The flag is what keeps "hold to reset"
/// from also advancing the panel.
class TouchArea extends PositionComponent with TapCallbacks {
  TouchArea({
    required this.onTap,
    required this.onLongPress,
    required Vector2 size,
  }) : super(size: size);

  final void Function() onTap;
  final void Function() onLongPress;

  bool _longFired = false;

  @override
  void onTapDown(TapDownEvent event) => _longFired = false;

  @override
  void onLongTapDown(TapDownEvent event) {
    _longFired = true;
    onLongPress();
  }

  @override
  void onTapUp(TapUpEvent event) {
    if (!_longFired) onTap();
  }
}
