import 'package:flutter/services.dart';
import 'package:sizzle/sizzle.dart';

import 'ambient.dart';
import 'display.dart';
import 'frame_rate_provider.dart';
import 'haptics.dart';
import 'power.dart';
import 'rotary.dart';

/// Wear OS platform support for Sizzle.
///
/// A static facade, mirroring `Services` in Sizzle itself - there is nothing
/// to instantiate. Call [attach] once during startup, then use [rotary] and
/// [display] anywhere.
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await SizzleWearable.attach();
///
///   runApp(GameWidget(game: SizzleGame(
///     scenes: {'game': GameScene.new},
///     targetSize: Vector2(192, 192),
///     frameRateMode: FrameRateMode.hardwareHalfRate,
///   )));
/// }
/// ```
///
/// Every member is safe to use on any platform. Off Wear OS the rotary stream
/// stays silent, display calls no-op, and [isSupported] is `false` - so the
/// same game runs on Windows during development without a single platform
/// check.
///
/// Rotary input additionally needs the app's activity to extend
/// `SizzleWearableActivity` (see the README), because generic motion events
/// are delivered to the activity and a plugin cannot intercept them alone.
class SizzleWearable {
  SizzleWearable._();

  static const MethodChannel _methods = MethodChannel('sizzle_wearable');
  static const EventChannel _rotaryEvents =
      EventChannel('sizzle_wearable/rotary');
  static const EventChannel _ambientEvents =
      EventChannel('sizzle_wearable/ambient');

  static final Rotary _rotary = Rotary(_rotaryEvents);
  static final WearableDisplay _display = WearableDisplay(_methods);
  static final Haptics _haptics = Haptics(_methods);
  static final WearableFrameRateProvider _frameRate =
      WearableFrameRateProvider(_methods);
  static final AmbientWearProvider _ambient =
      AmbientWearProvider(_ambientEvents);
  static final PowerWearProvider _power = PowerWearProvider(
    _methods,
    const EventChannel('sizzle_wearable/power'),
  );

  static bool _attached = false;
  static bool _isSupported = false;

  /// Whether this build is running on a Wear OS device with the plugin
  /// registered. `false` until [attach] has been awaited.
  static bool get isSupported => _isSupported;

  /// Rotary input from the bezel or crown. See [Rotary].
  ///
  /// Wear OS delivers crown, physical bezel and Samsung's *touch* bezel
  /// through the same rotary encoder events, so this works on watches with no
  /// rotating hardware at all - a Galaxy Watch5's touch bezel included.
  static Rotary get rotary => _rotary;

  /// Build identifiers for the device, or `null` off Wear OS.
  ///
  /// Keys: `manufacturer`, `brand`, `model`, `device`, `product`, `hardware`,
  /// `androidRelease`, `sdkInt`, `fingerprint`, `isWatch`.
  ///
  /// Intended for diagnostics and for keeping a per-device feature matrix -
  /// Wear behaviour varies between devices that report identical
  /// capabilities, so results are only meaningful when attributed.
  static Future<Map<String, dynamic>?> get deviceInfo =>
      _invoke<Map<dynamic, dynamic>>('deviceInfo')
          .then((r) => r?.map((k, v) => MapEntry(k as String, v)));

  /// What the display reports it can do, or `null` off Wear OS.
  ///
  /// Keys: `refreshRate` and `supportedRefreshRates`.
  ///
  /// Informational only. `supportedRefreshRates` does **not** predict whether
  /// a rate request will be honoured - that is measured, never inferred.
  /// Both battery-saver signals, for diagnosing devices where they disagree.
  ///
  /// Keys: `isPowerSaveMode` (the platform `PowerManager` flag, which is what
  /// [PowerProvider] reports) and `lowPowerSetting` (the raw
  /// `Settings.Global.LOW_POWER` integer, or -1 if unreadable).
  ///
  /// Wear OS has power modes of its own that do not necessarily move the
  /// platform flag, so when battery saver visibly changes device behaviour
  /// but Sizzle reports nothing, this is how you tell which layer is out of
  /// step.
  static Future<Map<String, dynamic>?> get powerDiagnostics =>
      _invoke<Map<dynamic, dynamic>>('powerDiagnostics')
          .then((r) => r?.map((k, v) => MapEntry(k as String, v)));

  /// What every attached rotary encoder publishes about itself, or `null` off
  /// Wear OS.
  ///
  /// Keys: `devices` (a list of maps carrying `id`, `name`, `sources` and the
  /// `AXIS_SCROLL` range's `min`, `max`, `resolution`, `flat` and `fuzz`, each
  /// null when the device publishes no such range) and `scrollFactor`.
  ///
  /// Answerable before any event arrives, which is the point of it: a device
  /// that publishes no usable `resolution` and a device that emits no rotary
  /// events at all look identical from the [Rotary] stream, and they want
  /// different fixes. `resolution` is the value [Rotary] divides raw scroll by
  /// to get radians, so reading it here is how you find out which path a watch
  /// is on without guessing from the manufacturer.
  ///
  /// `scrollFactor` is `ViewConfiguration.getScaledVerticalScrollFactor` -
  /// pixels of list scroll per scroll unit, carrying no angular information.
  /// Reported so numbers can be compared against Google's rotary samples.
  static Future<Map<String, dynamic>?> get rotaryDiagnostics =>
      _invoke<Map<dynamic, dynamic>>('rotaryDiagnostics')
          .then((r) => r?.map((k, v) => MapEntry(k as String, v)));

  static Future<Map<String, dynamic>?> get displayInfo =>
      _invoke<Map<dynamic, dynamic>>('displayInfo')
          .then((r) => r?.map((k, v) => MapEntry(k as String, v)));

  static Future<T?> _invoke<T>(String method) async {
    try {
      return await _methods.invokeMethod<T>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Display shape and window behaviour. See [WearableDisplay].
  static WearableDisplay get display => _display;

  /// The vibrator. See [Haptics].
  ///
  /// Works on any Android device the plugin is registered on, not only a
  /// watch, so a phone build used during development vibrates too. Off
  /// Android every call does nothing.
  static Haptics get haptics => _haptics;

  /// Wires the plugin into Sizzle and reports whether it found Wear OS.
  ///
  /// Registers [WearableFrameRateProvider] into `Device.hwFrameRateProvider`,
  /// which is what lets [FrameRateMode.hardwareHalfRate] resolve to real
  /// panel limiting rather than falling back to software. Idempotent.
  ///
  /// Call it before building the game widget, and after
  /// `WidgetsFlutterBinding.ensureInitialized()`.
  static Future<bool> attach() async {
    if (_attached) return _isSupported;
    _attached = true;

    try {
      _isSupported = await _methods.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      _isSupported = false;
    } on PlatformException {
      _isSupported = false;
    }

    // Asked whether or not this is a watch: see [haptics].
    await _haptics.info();

    if (_isSupported) {
      _frameRate.supported = true;
      Device.hwFrameRateProvider = _frameRate;
      _ambient.supported = true;
      Device.ambientProvider = _ambient;
      _power.supported = true;
      await _power.refresh();
      Device.powerProvider = _power;
    }
    return _isSupported;
  }

  /// Releases platform resources. Rarely needed - the OS reclaims everything
  /// on teardown - but useful in tests and when hot-restarting.
  static Future<void> detach() async {
    if (!_attached) return;
    await _rotary.dispose();
    _ambient.cancel();
    // Clear by identity: a second game may have installed its own.
    if (identical(Device.hwFrameRateProvider, _frameRate)) {
      Device.hwFrameRateProvider = null;
    }
    if (identical(Device.ambientProvider, _ambient)) {
      Device.ambientProvider = null;
    }
    _power.cancel();
    if (identical(Device.powerProvider, _power)) {
      Device.powerProvider = null;
    }
    _attached = false;
    _isSupported = false;
  }
}
