package io.paraplu.sizzle_wearable

import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import androidx.annotation.RequiresApi
import androidx.wear.ambient.AmbientLifecycleObserver
import io.flutter.embedding.android.FlutterActivity

/**
 * Drop-in replacement for `FlutterActivity` that wires up the activity-level
 * halves of Wear OS support.
 *
 * Three things can only be done from the activity, not from a plugin:
 *
 *  * **Rotary input.** Generic motion events are dispatched to the activity,
 *    so [onGenericMotionEvent] has to forward them to the plugin.
 *  * **Swipe-to-dismiss.** Wear maps the left-edge swipe to a back press;
 *    suppressing it means consuming that back press.
 *  * **Gesture exclusion.** The exclusion rects must be reapplied whenever the
 *    window is attached, regains focus, or changes layout - setting them once
 *    silently stops working.
 *
 * Use it in place of `FlutterActivity`:
 *
 * ```kotlin
 * package io.paraplu.mygame
 *
 * import io.paraplu.sizzle_wearable.SizzleWearableActivity
 *
 * class MainActivity : SizzleWearableActivity()
 * ```
 *
 * Behaviour is controlled from Dart via `SizzleWearable.display`, so the
 * activity itself needs no configuration.
 */
open class SizzleWearableActivity : FlutterActivity() {
    companion object {
        /**
         * When false, the left-edge dismiss gesture and its back press are
         * swallowed. Set from Dart via
         * `SizzleWearable.display.setSwipeToDismissEnabled`.
         */
        @JvmStatic
        var swipeToDismissEnabled: Boolean = true

        /**
         * When true, the whole window is excluded from system edge gestures.
         * Set from Dart via
         * `SizzleWearable.display.setGestureExclusionEnabled`.
         */
        @JvmStatic
        var gestureExclusionEnabled: Boolean = false
    }

    private val ambientCallback =
        object : AmbientLifecycleObserver.AmbientLifecycleCallback {
            override fun onEnterAmbient(
                ambientDetails: AmbientLifecycleObserver.AmbientDetails
            ) {
                SizzleWearablePlugin.onAmbientChanged(true)
            }

            override fun onExitAmbient() {
                SizzleWearablePlugin.onAmbientChanged(false)
            }

            // onUpdateAmbient is deliberately not implemented: Sizzle pauses
            // in ambient rather than repainting, so there is nothing to do.
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // FlutterActivity is a LifecycleOwner, so the observer can register
        // here directly - no need to rebase onto FlutterFragmentActivity.
        lifecycle.addObserver(AmbientLifecycleObserver(this, ambientCallback))
        // Re-assert across activity recreation, since the setting is static.
        applySwipeToDismissState()
    }

    override fun onGenericMotionEvent(event: MotionEvent?): Boolean =
        when {
            SizzleWearablePlugin.onGenericMotionEvent(event) -> true
            else -> super.onGenericMotionEvent(event)
        }

    /**
     * Legacy back handling, for API 32 and below only.
     *
     * From API 33 the system can route back through [OnBackInvokedDispatcher]
     * instead, and for apps targeting API 36+ predictive back is on by
     * default - at which point this method is *never called* and consuming
     * the swipe here silently stops working. See [applySwipeToDismissState].
     */
    @Deprecated("Superseded by OnBackInvokedCallback on API 33+")
    @Suppress("DEPRECATION", "MissingSuperCall")
    override fun onBackPressed() {
        if (!swipeToDismissEnabled) return
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    /**
     * A back callback that does nothing, which is precisely the point: a
     * registered callback at `PRIORITY_DEFAULT` consumes the back event and
     * suppresses the predictive-back animation, so the Wear dismiss swipe has
     * no effect.
     */
    @get:RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private val blockBackCallback: OnBackInvokedCallback by lazy {
        OnBackInvokedCallback { /* swallow */ }
    }

    private var backCallbackRegistered = false

    /**
     * Brings the registered back callback into line with
     * [swipeToDismissEnabled]. Idempotent, and safe to call before API 33
     * where it does nothing and [onBackPressed] handles it instead.
     */
    fun applySwipeToDismissState() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val shouldBlock = !swipeToDismissEnabled
        if (shouldBlock == backCallbackRegistered) return

        if (shouldBlock) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT,
                blockBackCallback,
            )
        } else {
            onBackInvokedDispatcher.unregisterOnBackInvokedCallback(
                blockBackCallback,
            )
        }
        backCallbackRegistered = shouldBlock
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        applyGestureExclusion()
        window.decorView.addOnLayoutChangeListener {
                _, _, _, _, _, _, _, _, _ ->
            applyGestureExclusion()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applyGestureExclusion()
    }

    private fun applyGestureExclusion() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val root: View = window.decorView
        root.systemGestureExclusionRects = if (gestureExclusionEnabled) {
            listOf(Rect(0, 0, root.width, root.height))
        } else {
            emptyList()
        }
    }
}
