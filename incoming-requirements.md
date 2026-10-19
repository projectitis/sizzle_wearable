# sizzle_wearable — Incoming Requirements

Requirements for the Wear OS plugin. Mirrors the format of Sizzle's own
`incoming-requirements.md`, but scoped to platform support rather than the
engine. Entries come from game projects or from on-device testing.

---

## Per-device rotary profile (direction and calibration)

- **Requested by**: On-device testing (Pixel Watch 3, Galaxy Watch5)
- **Description**: Ship a small table of known devices mapping build
  identifiers to rotary defaults - at minimum `invert`, and probably
  `magnitudeScale` / `tickAngle` too - and apply it automatically during
  `SizzleWearable.attach()`. Games would get sane behaviour out of the box and
  could still override afterwards.
- **Use case**: Rotary input is supposed to be transparent across crowns,
  physical bezels and touch bezels, but it is not. A clockwise finger movement
  on a Galaxy Watch5 touch bezel arrives with the **opposite sign** to a
  clockwise turn of a Pixel Watch 3 crown, and there is no way to detect which
  convention a device uses. Sensitivity diverges too: the Watch5 reports
  magnitude (one bezel revolution yields ~1.25 dial rotations at
  `magnitudeScale: 1.0`), while the PW3 crown reports none at all and is driven
  entirely by `tickAngle`. Today every game targeting both watches has to
  rediscover this and hard-code its own corrections.
- **Priority**: medium
- **Status**: pending
- **Notes**: Keyed on `Build.MANUFACTURER` + `Build.MODEL` (already exposed via
  `SizzleWearable.deviceInfo`); fall back to current defaults for unknown
  devices, never guess. Do **not** build this until there is more data - two
  devices is not a table.

  **Direction looks tabulatable; sensitivity does not.** The Galaxy Watch5 was
  re-tested on 2026-08-04 after updating to Wear OS 6 / API 36, same hardware:

  - `invert` **held** across three OS majors (API 30 -> 36). Both crowns (Pixel
    Watch 3, TicWatch Pro 5) report normal while the one touch bezel is
    reversed, so direction may reduce to a one-line input-type rule rather than
    a table at all.
  - The **1.25 ratio disappeared** - the same bezel now reads exactly 1:1 at
    `magnitudeScale: 1.0`. So it was a Wear OS 3 scroll-resolution quirk, *not*
    a device characteristic and *not* a bug in the plugin's
    `scroll / resolution` conversion. A per-device sensitivity table would have
    been wrong the moment the user updated their watch, which is an argument
    against building one.
  - *magnitude reported or not* is **not** input-type-specific - the two crowns
    disagree (PW3 reports none, TicWatch reports it) - so that part still has
    to be probed at runtime rather than assumed.
  The harness records `rotaryInverted`, `rotaryMagnitudeReported` and the
  one-revolution `angle` reading, so each new device adds a row for free.

<!-- Add new requirements above this line using the template below:

## [Feature Name]
- **Requested by**: [Game project name or source]
- **Description**: [What the feature should do]
- **Use case**: [How the game needs to use it]
- **Priority**: [high/medium/low]
- **Status**: pending
- **Notes**: [Any implementation hints or constraints]

-->
