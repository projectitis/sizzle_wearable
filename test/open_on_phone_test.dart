import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sizzle_wearable/sizzle_wearable.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('sizzle_wearable');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('sends the url and the confirm flag, and returns the reply', () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      seen = call;
      return true;
    });
    expect(
      await SizzleWearable.openOnPhone('https://example.com', confirm: false),
      isTrue,
    );
    expect(seen?.method, 'openOnPhone');
    expect(seen?.arguments, <String, Object>{
      'url': 'https://example.com',
      'confirm': false,
    });
  });

  test('is false when the phone refuses', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(await SizzleWearable.openOnPhone('https://example.com'), isFalse);
  });

  test('is false where the plugin is not registered', () async {
    expect(await SizzleWearable.openOnPhone('https://example.com'), isFalse);
  });

  test('is false when the platform throws', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'boom'),
    );
    expect(await SizzleWearable.openOnPhone('https://example.com'), isFalse);
  });
}
