import 'package:flutter/services.dart';

/// Watch display and window behaviour.
///
/// Everything here is a no-op that resolves to a safe default off Wear OS, so
/// a game can call these unconditionally and still run on desktop during
/// development.
class WearableDisplay {
  /// @nodoc
  WearableDisplay(MethodChannel channel) : _channel = channel;

  final MethodChannel _channel;

  bool? _isRound;

  /// Whether the display is circular.
  ///
  /// Backed by Android's `Configuration.isScreenRound()`, which is
  /// authoritative - unlike guessing from the aspect ratio, it correctly
  /// identifies round watches whose framebuffer is square, and correctly
  /// reports square watches. Cached after the first call, since a display
  /// does not change shape.
  ///
  /// Returns `false` off Wear OS.
  Future<bool> get isRound async {
    return _isRound ??= await _invoke<bool>('isRound') ?? false;
  }

  /// Keeps the display awake while the game is on screen.
  ///
  /// Sets or clears `FLAG_KEEP_SCREEN_ON`. Watches dim aggressively - often
  /// within a few seconds - so an action game generally wants this on during
  /// play and off in menus, to avoid flattening the battery when idle.
  Future<void> setKeepScreenOn(bool enabled) =>
      _invoke<void>('setKeepScreenOn', {'enabled': enabled});

  /// Whether a swipe from the left edge dismisses the app.
  ///
  /// Wear OS maps that gesture to "go back", which for a full-screen game is
  /// usually an accidental exit rather than an intent. Disabling it also
  /// suppresses the matching back-press, so the game can offer its own way
  /// out.
  ///
  /// Leave this enabled unless the game genuinely handles its own exit -
  /// users expect the gesture to work.
  ///
  /// **Requires Wear OS 6 (API 36+). Not an API 33 boundary.**
  ///
  /// On Wear OS 5 and earlier the dismiss swipe is handled at the *window*
  /// level and never becomes a back press, so there is nothing for the back
  /// callback to intercept no matter what API level the device reports.
  /// Measured across three devices:
  ///
  /// | Device | API | Result |
  /// |---|---|---|
  /// | Pixel Watch 3 | 37 | works |
  /// | Galaxy Watch5 (after update) | **36** | **works** |
  /// | TicWatch Pro 5 | **33** | **no effect** |
  /// | Galaxy Watch5 (before update) | 30 | no effect |
  ///
  /// The TicWatch is the informative one: it has the `OnBackInvokedDispatcher`
  /// this relies on, and blocking still does nothing. Do not infer support
  /// from the API level. The two Watch5 rows are the same physical device
  /// before and after its Wear OS 6 update, which pins the boundary to the OS
  /// rather than the hardware — and it working on a Samsung rules out this
  /// being a Pixel-only path.
  ///
  /// To block dismiss on *every* version, apply the plugin's theme to the
  /// activity in the app's manifest instead - a static choice, but the only
  /// one older Wear offers:
  ///
  /// ```xml
  /// <activity android:theme="@style/SizzleWearableNoDismiss" />
  /// ```
  Future<void> setSwipeToDismissEnabled(bool enabled) =>
      _invoke<void>('setSwipeToDismissEnabled', {'enabled': enabled});

  /// Stops the system consuming edge gestures over the whole display.
  ///
  /// Without this, drags that begin near the edge are swallowed by the system
  /// before the game sees them - painful on a round watch, where a large
  /// share of the usable area *is* near an edge. Applies
  /// `systemGestureExclusionRects` on Android 10+ and is a no-op below that.
  Future<void> setGestureExclusionEnabled(bool enabled) =>
      _invoke<void>('setGestureExclusionEnabled', {'enabled': enabled});

  /// The display's native audio output rate and buffer size, for configuring
  /// a low-latency audio engine.
  ///
  /// Wear devices commonly run at 48kHz with a small native burst size;
  /// feeding those exact values to an audio backend avoids resampling and
  /// keeps it on the fast path. Returns `null` off Wear OS, where the
  /// backend's own defaults are already right.
  ///
  /// Keys: `sampleRate` (Hz) and `framesPerBuffer`.
  Future<Map<String, int>?> get audioProperties async {
    final result = await _invoke<Map<dynamic, dynamic>>('audioProperties');
    if (result == null) return null;
    return result.map((k, v) => MapEntry(k as String, v as int));
  }

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // Not a Wear OS build; the caller gets a null/default and carries on.
      return null;
    } on PlatformException {
      return null;
    }
  }
}
