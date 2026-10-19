# sizzle_wearable

Wear OS platform support for the [Sizzle](https://github.com/projectitis/sizzle)
game engine.

Sizzle is pure Dart and runs anywhere. This plugin adds the Android/Wear OS
pieces that need native code, and registers them into Sizzle's provider seams
so the engine picks them up automatically.

> **Alpha.** Not published to pub.dev; use a path or git dependency.

> **Device reference:** measured per-device behaviour, and the development
> rules that follow from it, live in
> `D:/Paraplu/research/wearos-comparison.html`. Wear devices that look
> identical on paper behave differently — audio buffer sizes, rotary
> direction, refresh-rate honour and battery-saver signals all vary. Check
> there before assuming anything about hardware.

## What it does

| | |
|---|---|
| **Rotary input** | Bezel and crown rotation, as a stream *or* a game-loop accumulator |
| **Hardware frame rate** | Makes `FrameRateMode.hardwareHalfRate` resolve to real panel limiting |
| **Screen shape** | `Configuration.isScreenRound()` — authoritative, not an aspect-ratio guess |
| **Keep screen on** | Watches dim within seconds; hold the panel up during play |
| **Swipe-to-dismiss** | Suppress the accidental-exit gesture during gameplay |
| **Gesture exclusion** | Stop the system swallowing drags near the edge |
| **Ambient mode** | Always-on state + burn-in/low-bit constraints; stops the game and repaints once a minute |
| **Power save** | Battery saver state, so a game can trade quality for endurance |
| **Audio properties** | Native sample rate and buffer size, for low-latency audio setup |

Everything degrades to a safe no-op off Wear OS, so the same game still runs on
Windows during development without a single platform check.

## Setup

**1. Depend on it.**

```yaml
dependencies:
  sizzle:
    path: ../sizzle
  sizzle_wearable:
    path: ../sizzle_wearable
```

**2. Extend `SizzleWearableActivity`.** This is the only native change, and it
is required for rotary input — generic motion events are delivered to the
activity, so a plugin cannot intercept them on its own.

```kotlin
// android/app/src/main/kotlin/<your>/<package>/MainActivity.kt
package io.paraplu.mygame

import io.paraplu.sizzle_wearable.SizzleWearableActivity

class MainActivity : SizzleWearableActivity()
```

**3. Attach at startup**, before building the game widget.

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SizzleWearable.attach();

  runApp(GameWidget(game: SizzleGame(
    scenes: {'game': GameScene.new},
    targetSize: Vector2(192, 192),
    frameRateMode: FrameRateMode.hardwareHalfRate,
  )));
}
```

`attach()` returns whether it found Wear OS, and registers the hardware
frame-rate provider into `Device.hwFrameRateProvider`.

## Rotary input

Two ways to consume it. For game code, prefer the accumulator and drain it in
`fixedUpdate`:

```dart
class GameScene extends Scene {
  @override
  void fixedUpdate(double fixedDt) {
    turret.angle += SizzleWearable.rotary.consumeAngleDelta();
  }
}
```

Draining in `fixedUpdate` rather than `update` keeps input sampled at
`fixedUpdateFps` even when the game paints at half rate — which is the whole
point of Sizzle's decoupled clocks. Net rotation is identical either way; what
you gain is latency that does not scale with the paint rate.

Rotation reported is always proportional to rotation performed. Where the device
publishes an `AXIS_SCROLL` resolution — every watch measured so far does — the
raw scroll is divided by it and `rotary.magnitudeScale` tunes the result. `1.0`
means one turn of the hand is one turn in game, and that is both the default and
the measured value on a Pixel Watch 3 crown, a Galaxy Watch5 touch bezel and a
TicWatch Pro 5. Where a device publishes nothing usable,
`rotary.radiansPerScrollUnit` scales the raw units instead.

Note that is per scroll *unit*, not per event. Treating those as interchangeable
is a bug with a distinctive signature: rotation ends up proportional to how long
the control was moved rather than how far, so turning faster does less.

`rotary.resolutionOverride` replaces a resolution a device gets wrong, or
supplies one for a device that publishes none. Only its magnitude is used — a
negative resolution is valid (the Pixel crown reports `-0.791`) and its sign is
*not* a direction convention. Use `rotary.invert` for direction, and
`SizzleWearable.rotaryDiagnostics` plus `rotary.diagnostics` to see what a device
is actually reporting.

For UI-shaped code, `rotary.events` is a broadcast `Stream<RotaryEvent>`.

## Hardware frame rate, honestly

`Surface.setFrameRate` is a *hint*. Some devices honour it and genuinely drop
the panel refresh; many report support and then ignore the request. Supported
display modes do not predict which you have — a Pixel Watch 3 reports only
60Hz yet honours a 30fps request, while a TicWatch Pro 5 and Galaxy Watch5
report the same and ignore it.

So this plugin never claims success. It applies both available levers
(`preferredRefreshRate` and `Surface.setFrameRate` on Flutter's own
`SurfaceView`) and reports only that the request was *accepted*. Sizzle then
measures the real frame cadence and falls back to `softwareHalfRate` if the
display did not actually slow down. See Sizzle's `docs/frame_rate.md`.

## Testing

Meaningful tests must run on hardware:

```bash
cd example && flutter test integration_test
```

They also pass off-watch, where every wearable answer is expected to be "no" —
which is exactly the fallback path games rely on during development.

## Ambient mode

Handled for you: entering ambient stops the simulation and drops to a single
repaint per tick, rather than running a full-rate game on a dimmed screen. See
Sizzle's `docs/frame_rate.md` for what a scene should draw while it lasts, and
how to accrue idle progress from `SizzleMessage.ambientTick`.

Whether ambient happens at all is an OEM decision, not an OS-version one. Of
the devices tested, only the Pixel Watch 3 delivers it — a Galaxy Watch5 on
Wear OS 6 still logs the task as `no-ongoing` and backgrounds the app instead
of making it ambient, so the documented "apps targeting SDK 36 are always-on
automatically" does not hold there. Handle ambient so the game idles politely
where it does occur, but never build gameplay on ambient ticks.

## Out of scope

**Complications and tiles.** `ComplicationDataSourceService` and `TileService`
are system-rendered Android services: they never run the Flutter engine and
never touch `SizzleGame`. Supporting them would be a separate product with its
own testing story, not an increment on this plugin. If a Paraplu game ever
wants to publish a tile, that belongs in its own package.

**Battery percentage.** An engine cannot act on it sensibly, and
`battery_plus` already covers games that want it. Only power *save* state is
exposed, because that is an actionable signal.
