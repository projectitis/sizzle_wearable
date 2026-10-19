# Changes

## Unreleased

- **`SizzleWearable.haptics`** (2026-10-19): `info()`, `play(HapticEffect)` and
  `cancel()`. An effect is a list of tiers — composition, predefined, waveform —
  and the first one the device supports plays; the choice is
  `HapticsInfo.choose`, a pure function. Media vibration usage. The plugin now
  declares the `VIBRATE` permission. See the README's *Haptics* section.

## 0.1.0

- **Fixed: rotary input was not proportional to rotation.** When a device
  published no usable `AXIS_SCROLL` resolution, every event added a flat
  `tickAngle` regardless of how far the control had moved, so accumulation
  tracked event *count*. Event rate is capped by the input pipeline, so a fast
  turn arrived in fewer events than a slow one covering the same arc and
  reported less rotation — turning faster did less. The trigger was that a Pixel
  Watch 3 crown publishes `resolution = -0.791` and the plugin rejected anything
  `<= 0`; resolutions are now used by magnitude, and only NaN and zero count as
  unusable. Measured, one physical revolution now yields exactly 2π radians at
  `magnitudeScale = 1.0` on a Pixel Watch 3, a Galaxy Watch5 and a TicWatch
  Pro 5 alike.
- **`tickAngle` is now `radiansPerScrollUnit`** — radians per unit of raw scroll
  rather than per event. `tickAngle` remains as a deprecated alias, the default
  value is unchanged, and behaviour on hardware reporting one scroll unit per
  detent is unchanged; everything else gets the fix silently.
- `Rotary.resolutionOverride` overrides a resolution a device gets wrong, or
  supplies one for a device that publishes none. Only its magnitude is used: a
  negative resolution is valid and its sign is *not* a direction convention —
  the reversed device measured is the one with the positive resolution.
- `RotaryEvent` gains `radians` (signed, always present, exactly what the
  accumulator counted), `scroll` (raw) and `deviceRadians`. `magnitude` is
  deprecated in favour of `radians`. Note it is now **never null**, so code
  testing it for null to ask whether the device reports proportional rotation
  will silently answer "always yes"; ask `deviceRadians != null` instead, which
  is null exactly when no usable resolution was published.
- `Rotary.diagnostics` / `resetDiagnostics` report what the hardware is actually
  doing: event and sample counts, batching, raw scroll totals, the published
  resolution, event rate and peak angular rate. Collected unconditionally, so an
  input problem can be diagnosed from whatever build is on the watch.
- `SizzleWearable.rotaryDiagnostics` reports every attached rotary encoder's
  `AXIS_SCROLL` range *before* any event arrives, which separates "publishes no
  usable resolution" from "emits nothing at all".
- Rotary events now sum batched historical samples rather than reading only the
  newest. No measured device batches these (`historySize` was 1 sample
  throughout), so this closes a latent hole rather than a live one.
- Malformed platform payloads can no longer throw out of the rotary stream, and
  a non-finite scroll value can no longer poison the accumulator permanently.
- The example app gains a rotary calibration screen, reached by long-pressing
  the demo: a 1:1 dial, what the device publishes about itself, and the totals a
  calibration constant is derived from.
- Ambient (always-on) mode via `androidx.wear.ambient.AmbientLifecycleObserver`,
  registered by `SizzleWearableActivity`. Reports burn-in and low-bit
  constraints as well as the transition itself, and drives Sizzle's
  `AmbientProvider` seam. Adds the `WAKE_LOCK` permission and the plugin's
  first `androidx` dependency (`androidx.wear:wear`).
- Battery saver state via `PowerManager.isPowerSaveMode` and
  `ACTION_POWER_SAVE_MODE_CHANGED`, driving Sizzle's `PowerProvider` seam.

## 0.0.1

- Initial version.
- Rotary input (bezel and crown) as a stream or a game-loop accumulator,
  replacing the discontinued `wearable_rotary`.
- Hardware frame rate limiting, so `FrameRateMode.hardwareHalfRate` can resolve
  to real panel limiting.
- Screen shape via `Configuration.isScreenRound()`.
- Keep-screen-on, swipe-to-dismiss suppression and system gesture exclusion.
- Native audio sample rate and buffer size, for low-latency audio setup.
