import 'dart:async';

import 'package:flutter/services.dart';
import 'package:sizzle/sizzle.dart';

/// Wear OS implementation of Sizzle's [PowerProvider], backed by
/// `PowerManager.isPowerSaveMode` and the matching system broadcast.
///
/// Registered into `Device.powerProvider` by `SizzleWearable.attach()`.
class PowerWearProvider implements PowerProvider {
  /// @nodoc
  PowerWearProvider(this._methods, this._events);

  final MethodChannel _methods;
  final EventChannel _events;

  StreamSubscription<dynamic>? _subscription;
  void Function(bool isPowerSaveMode)? _onChanged;
  bool _isPowerSaveMode = false;
  bool _supported = false;

  /// Set during `SizzleWearable.attach()` from the platform's own answer.
  /// @nodoc
  set supported(bool value) => _supported = value;

  @override
  bool get isSupported => _supported;

  @override
  bool get isPowerSaveMode => _isPowerSaveMode;

  /// Reads the current state once, so the game starts with the truth rather
  /// than waiting for the first transition. Called by `attach()`.
  /// @nodoc
  Future<void> refresh() async {
    try {
      _isPowerSaveMode =
          await _methods.invokeMethod<bool>('isPowerSaveMode') ?? false;
    } on MissingPluginException {
      _isPowerSaveMode = false;
    } on PlatformException {
      _isPowerSaveMode = false;
    }
  }

  @override
  void listen({required void Function(bool isPowerSaveMode) onChanged}) {
    _onChanged = onChanged;
    if (_subscription != null) return;
    try {
      _subscription = _events.receiveBroadcastStream().listen(
        (dynamic raw) {
          if (raw is! bool || raw == _isPowerSaveMode) return;
          _isPowerSaveMode = raw;
          _onChanged?.call(raw);
        },
        onError: (Object _) {},
      );
    } on MissingPluginException {
      // Not a Wear OS build; the state stays false forever.
    }
  }

  @override
  void cancel() {
    _subscription?.cancel();
    _subscription = null;
    _onChanged = null;
  }
}
