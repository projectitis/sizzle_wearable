import 'dart:async';

import 'package:flutter/services.dart';
import 'package:sizzle/sizzle.dart';

/// Wear OS implementation of Sizzle's [AmbientProvider], backed by
/// `androidx.wear.ambient.AmbientLifecycleObserver`.
///
/// This exists to *stop* the game, not to render an ambient screen. On Wear
/// OS 6+ an app targeting SDK 36 is always-on whether it asks to be or not -
/// the activity stays resumed when the watch dims and no lifecycle callback
/// arrives - so without this a game would keep simulating and painting at
/// full rate on a display nobody is looking at. There is no way to opt out of
/// that platform behaviour.
///
/// Registered into `Device.ambientProvider` by `SizzleWearable.attach()`.
/// Transitions are delivered by the host activity, so this only works when
/// the app's activity extends `SizzleWearableActivity`.
class AmbientWearProvider implements AmbientProvider {
  /// @nodoc
  AmbientWearProvider(EventChannel channel) : _channel = channel;

  final EventChannel _channel;

  StreamSubscription<dynamic>? _subscription;
  void Function(bool isAmbient)? _onChanged;

  bool _supported = false;

  /// Set during `SizzleWearable.attach()` from the platform's own answer.
  /// @nodoc
  set supported(bool value) => _supported = value;

  @override
  bool get isSupported => _supported;

  @override
  void listen({required void Function(bool isAmbient) onChanged}) {
    _onChanged = onChanged;
    if (_subscription != null) return;
    try {
      _subscription = _channel.receiveBroadcastStream().listen(
        (dynamic raw) {
          if (raw is bool) _onChanged?.call(raw);
        },
        onError: (Object _) {},
      );
    } on MissingPluginException {
      // Not a Wear OS build; the game simply never goes ambient.
    }
  }

  @override
  void cancel() {
    _subscription?.cancel();
    _subscription = null;
    _onChanged = null;
  }
}
