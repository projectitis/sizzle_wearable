import 'package:flutter/services.dart';
import 'package:sizzle/sizzle.dart';

/// Wear OS implementation of Sizzle's [HwFrameRateProvider], backed by
/// Android's `Surface.setFrameRate`.
///
/// Registered into `Device.hwFrameRateProvider` by `SizzleWearable.attach()`,
/// which is what makes [FrameRateMode.hardwareHalfRate] resolve to real
/// hardware limiting instead of falling back to software.
///
/// Note that [setHardwareFrameRate] returning `true` only means the platform
/// *accepted* the request. Whether the panel actually slowed down is a
/// separate question, and one that varies between devices that report
/// identical capabilities - a Pixel Watch 3 honours a 30fps request while a
/// TicWatch Pro 5 and Galaxy Watch5 quietly ignore it. Sizzle settles that by
/// measuring the resulting frame cadence, so this class never has to guess.
class WearableFrameRateProvider implements HwFrameRateProvider {
  /// @nodoc
  WearableFrameRateProvider(MethodChannel channel) : _channel = channel;

  final MethodChannel _channel;

  bool _supported = false;

  /// Set during `SizzleWearable.attach()` from the platform's own answer.
  /// @nodoc
  set supported(bool value) => _supported = value;

  @override
  bool get isSupported => _supported;

  @override
  Future<bool> setHardwareFrameRate(double fps) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setFrameRate',
        {'fps': fps},
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clearFrameRate');
    } on MissingPluginException {
      // Nothing was ever applied.
    } on PlatformException {
      // Best-effort; the surface returns to its default on teardown anyway.
    }
  }
}
