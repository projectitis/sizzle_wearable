import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's predefined vibration effects that a game can name.
///
/// These are the four that every watch probed on 2026-10-19 supports (Galaxy
/// Watch5 on API 36, TicWatch Pro 5 on API 33, Pixel Watch 3 on API 37).
/// `THUD` and `POP` are left out on purpose: the Pixel Watch 3 reports neither
/// and silently plays nothing when asked for one without a fallback.
enum HapticPreset { tick, click, heavyClick, doubleClick }

/// Android's composition primitives (`VibrationEffect.Composition`).
///
/// **Support and length both vary per watch**, so a composition is only ever
/// played where [HapticsInfo.primitives] lists every primitive it uses.
/// Measured 2026-10-19: the Galaxy Watch5 supports none; the TicWatch Pro 5 and
/// Pixel Watch 3 support all of these, but `thud` lasts 21 ms on the first and
/// 247 ms on the second, and `slowRise` 17 ms against 500 ms. A composition
/// tuned on one watch does not feel the same on another.
enum HapticPrimitive {
  click,
  thud,
  spin,
  quickRise,
  slowRise,
  quickFall,
  tick,
  lowTick,
}

/// One way of playing an effect. A [HapticEffect] lists several, best first.
sealed class HapticTier {
  const HapticTier();
}

/// A predefined effect. Needs the watch to report [preset] as supported.
class HapticPredefined extends HapticTier {
  const HapticPredefined(this.preset);

  final HapticPreset preset;
}

/// One primitive in a [HapticComposition].
class HapticPart {
  const HapticPart(this.primitive, {this.scale = 1.0, this.delayMs = 0});

  final HapticPrimitive primitive;

  /// Strength, 0..1.
  final double scale;

  /// Silence before this primitive starts, in milliseconds.
  final int delayMs;
}

/// A sequence of primitives. Needs every primitive in [parts] to be supported.
class HapticComposition extends HapticTier {
  const HapticComposition(this.parts);

  final List<HapticPart> parts;
}

/// One step of a [HapticWaveform]: [ms] milliseconds at [amplitude] (0..1,
/// where 0 is off).
class HapticStep {
  const HapticStep(this.ms, this.amplitude);

  final int ms;
  final double amplitude;
}

/// A sequence of fixed-amplitude steps.
///
/// Plays on any watch with a vibrator. On a watch without amplitude control
/// every step above zero plays at full strength, so the waveform degrades to
/// an on/off pattern with the same timing rather than not playing at all.
class HapticWaveform extends HapticTier {
  const HapticWaveform(this.steps, {this.repeatFrom});

  final List<HapticStep> steps;

  /// When set, the waveform loops back to this step index after the last step
  /// and plays until [Haptics.cancel] or another effect replaces it.
  final int? repeatFrom;

  /// The length of one pass through [steps], in milliseconds.
  int get durationMs => steps.fold(0, (int sum, HapticStep s) => sum + s.ms);
}

/// An effect, as a list of tiers tried in order.
///
/// [Haptics.play] plays the first tier this watch supports — see
/// [HapticsInfo.choose] — so a richer tier can sit above a plainer fallback.
class HapticEffect {
  const HapticEffect(this.tiers);

  final List<HapticTier> tiers;
}

/// What a watch's vibrator reports it can do.
class HapticsInfo {
  const HapticsInfo({
    required this.hasVibrator,
    required this.amplitudeControl,
    required this.presets,
    required this.primitives,
    this.resonantHz,
  });

  /// The answer off Android, or when the platform could not be asked.
  static const HapticsInfo none = HapticsInfo(
    hasVibrator: false,
    amplitudeControl: false,
    presets: <HapticPreset>{},
    primitives: <HapticPrimitive, int?>{},
  );

  /// Parses the `hapticsInfo` method's reply. Unknown ids are dropped.
  factory HapticsInfo.fromPlatform(Map<dynamic, dynamic> raw) {
    final Set<HapticPreset> presets = <HapticPreset>{};
    for (final Object? id in (raw['presets'] as List<dynamic>?) ?? const []) {
      final HapticPreset? preset = _presetFromId(id);
      if (preset != null) presets.add(preset);
    }
    final Map<HapticPrimitive, int?> primitives = <HapticPrimitive, int?>{};
    final Map<dynamic, dynamic> rawPrimitives =
        (raw['primitives'] as Map<dynamic, dynamic>?) ?? const {};
    rawPrimitives.forEach((Object? id, Object? ms) {
      final HapticPrimitive? primitive = _primitiveFromId(id);
      if (primitive != null) primitives[primitive] = ms as int?;
    });
    return HapticsInfo(
      hasVibrator: raw['hasVibrator'] as bool? ?? false,
      amplitudeControl: raw['amplitudeControl'] as bool? ?? false,
      presets: presets,
      primitives: primitives,
      resonantHz: (raw['resonantHz'] as num?)?.toDouble(),
    );
  }

  final bool hasVibrator;

  /// Whether a waveform's amplitudes are honoured. See [HapticWaveform].
  final bool amplitudeControl;

  /// The predefined effects the watch reports as supported.
  final Set<HapticPreset> presets;

  /// The supported primitives, each with its length in milliseconds where
  /// the platform reports one (API 31+), otherwise `null`.
  final Map<HapticPrimitive, int?> primitives;

  /// The motor's resonant frequency, where the watch reports one.
  final double? resonantHz;

  /// The first tier of [effect] this watch can play, or `null` for none.
  HapticTier? choose(HapticEffect effect) {
    if (!hasVibrator) return null;
    for (final HapticTier tier in effect.tiers) {
      switch (tier) {
        case HapticPredefined(:final HapticPreset preset):
          if (presets.contains(preset)) return tier;
        case HapticComposition(:final List<HapticPart> parts):
          if (parts
              .every((HapticPart p) => primitives.containsKey(p.primitive))) {
            return tier;
          }
        case HapticWaveform():
          return tier;
      }
    }
    return null;
  }

  /// The method-channel arguments that play [tier] on this watch.
  @visibleForTesting
  Map<String, Object> encode(HapticTier tier) {
    switch (tier) {
      case HapticPredefined(:final HapticPreset preset):
        return <String, Object>{'kind': 'predefined', 'id': _presetId(preset)};
      case HapticComposition(:final List<HapticPart> parts):
        return <String, Object>{
          'kind': 'composition',
          'ids': [for (final HapticPart p in parts) _primitiveId(p.primitive)],
          'scales': [for (final HapticPart p in parts) p.scale.clamp(0.0, 1.0)],
          'delays': [for (final HapticPart p in parts) p.delayMs],
        };
      case HapticWaveform(
          :final List<HapticStep> steps,
          :final int? repeatFrom
        ):
        return <String, Object>{
          'kind': 'waveform',
          'timings': [for (final HapticStep s in steps) s.ms],
          'amplitudes': [for (final HapticStep s in steps) _amplitude(s)],
          'repeat': repeatFrom ?? -1,
        };
    }
  }

  /// 0..1 to Android's 0..255, where 0 is off and anything above it is at
  /// least 1. Without amplitude control every audible step is full strength.
  int _amplitude(HapticStep step) {
    if (step.amplitude <= 0) return 0;
    if (!amplitudeControl) return 255;
    return (step.amplitude * 255).round().clamp(1, 255);
  }

  // Android's `VibrationEffect.EFFECT_*` ids.
  static int _presetId(HapticPreset preset) => switch (preset) {
        HapticPreset.click => 0,
        HapticPreset.doubleClick => 1,
        HapticPreset.tick => 2,
        HapticPreset.heavyClick => 5,
      };

  static HapticPreset? _presetFromId(Object? id) => switch (id) {
        0 => HapticPreset.click,
        1 => HapticPreset.doubleClick,
        2 => HapticPreset.tick,
        5 => HapticPreset.heavyClick,
        _ => null,
      };

  // Android's `VibrationEffect.Composition.PRIMITIVE_*` ids.
  static int _primitiveId(HapticPrimitive primitive) => switch (primitive) {
        HapticPrimitive.click => 1,
        HapticPrimitive.thud => 2,
        HapticPrimitive.spin => 3,
        HapticPrimitive.quickRise => 4,
        HapticPrimitive.slowRise => 5,
        HapticPrimitive.quickFall => 6,
        HapticPrimitive.tick => 7,
        HapticPrimitive.lowTick => 8,
      };

  static HapticPrimitive? _primitiveFromId(Object? id) {
    for (final HapticPrimitive p in HapticPrimitive.values) {
      if (_primitiveId(p) == id) return p;
    }
    return null;
  }
}

/// The watch's vibrator.
///
/// [play] and [cancel] are fire-and-forget: nothing waits on the platform
/// channel, so they are safe to call from a game's update. Off Android, or
/// until [info] has resolved, both do nothing.
///
/// Effects are played with the media vibration usage (`USAGE_MEDIA` on API
/// 33+, `AudioAttributes.USAGE_GAME` below), which Android documents for
/// games: the player's media vibration strength scales them, and turning off
/// touch vibration does not silence them. A new effect replaces whatever is
/// playing, so a game that wants a stronger effect to finish uninterrupted has
/// to hold the weaker one back itself.
class Haptics {
  /// @nodoc
  Haptics(MethodChannel channel) : _channel = channel;

  final MethodChannel _channel;

  HapticsInfo? _info;
  Future<HapticsInfo>? _loading;

  /// What the vibrator can do. Asked once and cached;
  /// `SizzleWearable.attach` asks it, so after that [cachedInfo] is set.
  Future<HapticsInfo> info() => _loading ??= _load();

  /// [info]'s answer, or `null` until it has resolved.
  HapticsInfo? get cachedInfo => _info;

  Future<HapticsInfo> _load() async {
    HapticsInfo info = HapticsInfo.none;
    try {
      final Map<dynamic, dynamic>? raw =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('hapticsInfo');
      if (raw != null) info = HapticsInfo.fromPlatform(raw);
    } on MissingPluginException {
      // Not an Android build.
    } on PlatformException {
      // Leave it at none.
    }
    return _info = info;
  }

  /// Plays the first tier of [effect] this watch supports, replacing whatever
  /// is playing. Does nothing when no tier fits.
  void play(HapticEffect effect) {
    final HapticsInfo? info = _info;
    if (info == null) return;
    final HapticTier? tier = info.choose(effect);
    if (tier == null) return;
    _send('hapticPlay', info.encode(tier));
  }

  /// Stops whatever is playing.
  void cancel() {
    final HapticsInfo? info = _info;
    if (info == null || !info.hasVibrator) return;
    _send('hapticCancel', null);
  }

  void _send(String method, Map<String, Object>? args) {
    unawaited(
      _channel.invokeMethod<void>(method, args).catchError((Object _) {}),
    );
  }
}
