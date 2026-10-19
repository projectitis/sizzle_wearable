// On-device integration tests.
//
// These are the only tests that can tell the truth about a plugin, because the
// answers depend on the hardware underneath. Run them on a real watch:
//
//   cd example && flutter test integration_test
//
// They also pass on a phone or desktop, where every wearable answer is
// expected to be "no" - which is exactly the fallback behaviour a game relies
// on during development.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sizzle/sizzle.dart';
import 'package:sizzle_wearable/sizzle_wearable.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(SizzleWearable.detach);

  testWidgets('attach reports whether this is a Wear OS device', (_) async {
    final supported = await SizzleWearable.attach();
    expect(supported, SizzleWearable.isSupported);
  });

  testWidgets('attach registers a frame rate provider only on Wear OS', (
    _,
  ) async {
    await SizzleWearable.attach();

    if (SizzleWearable.isSupported) {
      expect(Device.hwFrameRateProvider, isNotNull);
      expect(Device.isHWFrameRateSupported, isTrue);
    } else {
      // Off Wear OS nothing is registered, so hardwareHalfRate keeps
      // resolving to its software fallback.
      expect(Device.hwFrameRateProvider, isNull);
      expect(Device.isHWFrameRateSupported, isFalse);
    }
  });

  testWidgets('attach is idempotent', (_) async {
    final first = await SizzleWearable.attach();
    final second = await SizzleWearable.attach();
    expect(first, second);
  });

  testWidgets('display queries resolve without throwing anywhere', (_) async {
    await SizzleWearable.attach();

    // Off Wear these no-op; on Wear they hit the platform. Neither should ever
    // throw at a call site.
    await SizzleWearable.display.setKeepScreenOn(true);
    await SizzleWearable.display.setGestureExclusionEnabled(true);
    await SizzleWearable.display.setSwipeToDismissEnabled(false);
    await SizzleWearable.display.setKeepScreenOn(false);

    final round = await SizzleWearable.display.isRound;
    if (!SizzleWearable.isSupported) {
      expect(round, isFalse);
    }
  });

  testWidgets('rotary reports no rotation without hardware', (_) async {
    await SizzleWearable.attach();
    expect(SizzleWearable.rotary.consumeAngleDelta(), 0.0);
  });

  testWidgets('audio properties are present on Wear, absent elsewhere', (
    _,
  ) async {
    await SizzleWearable.attach();
    final props = await SizzleWearable.display.audioProperties;

    if (SizzleWearable.isSupported) {
      expect(props, isNotNull);
      expect(props!['sampleRate'], greaterThan(0));
      expect(props['framesPerBuffer'], greaterThan(0));
    } else {
      expect(props, isNull);
    }
  });
}
