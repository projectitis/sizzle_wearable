import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sizzle_wearable/sizzle_wearable.dart';

/// The three watches as `dumpsys vibrator_manager` described them on
/// 2026-10-19, shaped as the `hapticsInfo` method replies.
const Map<String, Object> _galaxyWatch5 = <String, Object>{
  'hasVibrator': true,
  'amplitudeControl': true,
  'presets': <int>[0, 1, 2, 5],
  'primitives': <int, int?>{},
};

const Map<String, Object> _ticWatchPro5 = <String, Object>{
  'hasVibrator': true,
  'amplitudeControl': true,
  'presets': <int>[0, 1, 2, 3, 4, 5],
  'primitives': <int, int?>{
    1: 34,
    2: 21,
    3: 42,
    4: 21,
    5: 17,
    6: 53,
    7: 6,
    8: 4,
  },
};

const Map<String, Object> _pixelWatch3 = <String, Object>{
  'hasVibrator': true,
  'amplitudeControl': true,
  'presets': <int>[0, 1, 2, 5, 21],
  'primitives': <int, int?>{
    1: 25,
    2: 247,
    3: 166,
    4: 150,
    5: 500,
    6: 100,
    7: 6,
    8: 17,
  },
  'resonantHz': 157.74,
};

const HapticEffect _thudOrClickOrBuzz = HapticEffect(<HapticTier>[
  HapticComposition(<HapticPart>[HapticPart(HapticPrimitive.thud)]),
  HapticPredefined(HapticPreset.heavyClick),
  HapticWaveform(<HapticStep>[HapticStep(40, 1.0)]),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HapticsInfo.fromPlatform', () {
    test('reads the probed watches, dropping ids with no public name', () {
      final HapticsInfo pixel = HapticsInfo.fromPlatform(_pixelWatch3);
      expect(pixel.presets, <HapticPreset>{
        HapticPreset.click,
        HapticPreset.doubleClick,
        HapticPreset.tick,
        HapticPreset.heavyClick,
      });
      expect(pixel.primitives[HapticPrimitive.thud], 247);
      expect(pixel.primitives.length, HapticPrimitive.values.length);
      expect(pixel.resonantHz, closeTo(157.74, 1e-9));

      final HapticsInfo galaxy = HapticsInfo.fromPlatform(_galaxyWatch5);
      expect(galaxy.primitives, isEmpty);
      expect(galaxy.resonantHz, isNull);
    });

    test('an empty reply is no vibrator', () {
      final HapticsInfo info = HapticsInfo.fromPlatform(const {});
      expect(info.hasVibrator, isFalse);
      expect(info.choose(_thudOrClickOrBuzz), isNull);
    });
  });

  group('HapticsInfo.choose', () {
    test('a watch with primitives takes the composition', () {
      expect(
        HapticsInfo.fromPlatform(_ticWatchPro5).choose(_thudOrClickOrBuzz),
        isA<HapticComposition>(),
      );
      expect(
        HapticsInfo.fromPlatform(_pixelWatch3).choose(_thudOrClickOrBuzz),
        isA<HapticComposition>(),
      );
    });

    test('the Galaxy Watch5 falls back to the predefined effect', () {
      expect(
        HapticsInfo.fromPlatform(_galaxyWatch5).choose(_thudOrClickOrBuzz),
        isA<HapticPredefined>(),
      );
    });

    test('one missing primitive rules out the whole composition', () {
      const HapticsInfo noSpin = HapticsInfo(
        hasVibrator: true,
        amplitudeControl: true,
        presets: <HapticPreset>{},
        primitives: <HapticPrimitive, int?>{HapticPrimitive.thud: 20},
      );
      const HapticEffect effect = HapticEffect(<HapticTier>[
        HapticComposition(<HapticPart>[
          HapticPart(HapticPrimitive.thud),
          HapticPart(HapticPrimitive.spin),
        ]),
        HapticWaveform(<HapticStep>[HapticStep(40, 1.0)]),
      ]);
      expect(noSpin.choose(effect), isA<HapticWaveform>());
    });

    test('a waveform plays on any vibrator, with or without amplitude', () {
      const HapticsInfo bare = HapticsInfo(
        hasVibrator: true,
        amplitudeControl: false,
        presets: <HapticPreset>{},
        primitives: <HapticPrimitive, int?>{},
      );
      expect(bare.choose(_thudOrClickOrBuzz), isA<HapticWaveform>());
    });

    test('an effect with no tier this watch supports plays nothing', () {
      const HapticEffect onlyThud = HapticEffect(<HapticTier>[
        HapticComposition(<HapticPart>[HapticPart(HapticPrimitive.thud)]),
      ]);
      expect(HapticsInfo.fromPlatform(_galaxyWatch5).choose(onlyThud), isNull);
    });
  });

  group('HapticsInfo.encode', () {
    test('waveform amplitudes map 0..1 to 0..255, keeping 0 as off', () {
      final Map<String, Object> args =
          HapticsInfo.fromPlatform(_galaxyWatch5).encode(
        const HapticWaveform(
          <HapticStep>[
            HapticStep(30, 0.0),
            HapticStep(30, 0.001),
            HapticStep(30, 0.5),
            HapticStep(30, 1.0),
          ],
          repeatFrom: 1,
        ),
      );
      expect(args['kind'], 'waveform');
      expect(args['timings'], <int>[30, 30, 30, 30]);
      expect(args['amplitudes'], <int>[0, 1, 128, 255]);
      expect(args['repeat'], 1);
    });

    test('without amplitude control a waveform becomes on/off', () {
      const HapticsInfo bare = HapticsInfo(
        hasVibrator: true,
        amplitudeControl: false,
        presets: <HapticPreset>{},
        primitives: <HapticPrimitive, int?>{},
      );
      final Map<String, Object> args = bare.encode(
        const HapticWaveform(<HapticStep>[
          HapticStep(20, 0.2),
          HapticStep(20, 0.0),
        ]),
      );
      expect(args['amplitudes'], <int>[255, 0]);
      expect(args['repeat'], -1);
    });

    test('presets and primitives use the Android ids', () {
      final HapticsInfo pixel = HapticsInfo.fromPlatform(_pixelWatch3);
      expect(
        pixel.encode(const HapticPredefined(HapticPreset.heavyClick))['id'],
        5,
      );
      final Map<String, Object> args = pixel.encode(
        const HapticComposition(<HapticPart>[
          HapticPart(HapticPrimitive.lowTick, scale: 0.3),
          HapticPart(HapticPrimitive.thud, scale: 1.4, delayMs: 80),
        ]),
      );
      expect(args['ids'], <int>[8, 2]);
      expect(args['scales'], <double>[0.3, 1.0]);
      expect(args['delays'], <int>[0, 80]);
    });
  });

  group('Haptics', () {
    const MethodChannel channel = MethodChannel('test/haptics');
    late List<MethodCall> calls;

    void reply(Map<String, Object>? info) {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return call.method == 'hapticsInfo' ? info : null;
      });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('plays nothing until info has resolved', () async {
      reply(_galaxyWatch5);
      final Haptics haptics = Haptics(channel);
      haptics.play(_thudOrClickOrBuzz);
      expect(calls, isEmpty);

      await haptics.info();
      haptics.play(_thudOrClickOrBuzz);
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((MethodCall c) => c.method), <String>[
        'hapticsInfo',
        'hapticPlay',
      ]);
      final Map<dynamic, dynamic> args =
          calls.last.arguments as Map<dynamic, dynamic>;
      expect(args['kind'], 'predefined');
    });

    test('info is asked once', () async {
      reply(_pixelWatch3);
      final Haptics haptics = Haptics(channel);
      await haptics.info();
      await haptics.info();
      final int asked =
          calls.where((MethodCall c) => c.method == 'hapticsInfo').length;
      expect(asked, 1);
    });

    test('a missing plugin is no vibrator and every call is a no-op', () async {
      final Haptics haptics = Haptics(const MethodChannel('test/unregistered'));
      expect((await haptics.info()).hasVibrator, isFalse);
      haptics.play(_thudOrClickOrBuzz);
      haptics.cancel();
    });
  });
}
