package io.paraplu.sizzle_wearable

/**
 * The arithmetic behind rotary event handling, kept free of Android types.
 *
 * Split out of [SizzleWearablePlugin] purely so it can be unit tested: anything
 * touching `MotionEvent` or `InputDevice` needs an instrumented test or a pile
 * of mocks, and the part actually worth testing is this.
 */
internal object RotaryScroll {
    /**
     * Total scroll carried by one motion event: every historical sample plus
     * the current one.
     *
     * `MotionEvent.getAxisValue` returns only the newest sample. When the input
     * pipeline batches, the older samples are reachable solely through
     * `getHistoricalAxisValue`, and the current sample is *in addition to* the
     * history rather than a repeat of its last entry - so this sums both.
     *
     * Dropping the history loses rotation in proportion to how much batching
     * happened, and batching grows with input rate, so the loss grows with how
     * fast the crown is turned. The player feels a control that goes numb
     * exactly when they hurry.
     */
    fun sumAxis(current: Float, historical: FloatArray): Float {
        var total = current
        for (value in historical) total += value
        return total
    }
}
