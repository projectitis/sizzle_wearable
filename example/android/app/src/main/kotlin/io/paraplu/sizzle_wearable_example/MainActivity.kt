package io.paraplu.sizzle_wearable_example

import io.paraplu.sizzle_wearable.SizzleWearableActivity

/**
 * Extending [SizzleWearableActivity] instead of `FlutterActivity` is the only
 * native change a Sizzle game needs: it forwards rotary motion events to the
 * plugin and owns the dismiss-gesture and gesture-exclusion behaviour.
 */
class MainActivity : SizzleWearableActivity()
