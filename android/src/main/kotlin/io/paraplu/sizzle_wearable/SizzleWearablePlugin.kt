package io.paraplu.sizzle_wearable

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Rect
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Wear OS platform support for the Sizzle game engine.
 *
 * Rotary events arrive through [onGenericMotionEvent], which the host activity
 * must forward: generic motion events are delivered to the activity and a
 * plugin cannot intercept them on its own. Extending [SizzleWearableActivity]
 * wires that up for you.
 */
class SizzleWearablePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var rotaryChannel: EventChannel
    private var applicationContext: Context? = null
    private var activity: Activity? = null
    private var rotarySink: EventChannel.EventSink? = null
    private lateinit var ambientChannel: EventChannel
    private var ambientSink: EventChannel.EventSink? = null
    private lateinit var powerChannel: EventChannel
    private var powerSink: EventChannel.EventSink? = null
    private var powerReceiver: BroadcastReceiver? = null
    private var powerObserver: ContentObserver? = null
    private var lastPowerSaveMode = false

    /**
     * How often each detection path has fired. Reported by
     * `powerDiagnostics` so a device where one works and the other does not
     * can be told apart from one where neither is wired up at all.
     */
    private var broadcastFires = 0
    private var observerFires = 0

    /**
     * Battery saver changes are watched two ways, because on Wear OS the
     * broadcast alone has been observed not to arrive.
     *
     *  1. `ACTION_POWER_SAVE_MODE_CHANGED`, the documented signal.
     *  2. A [ContentObserver] on `Settings.Global.LOW_POWER`, which is the
     *     setting `adb shell settings put global low_power 1` writes and
     *     which the system UI toggle normally updates too.
     *
     * Whichever fires first wins; [emitPowerSave] de-duplicates so a device
     * that delivers both does not report the change twice.
     */
    private val powerStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            powerSink = events
            val context = applicationContext ?: return
            lastPowerSaveMode = isPowerSaveMode()

            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    broadcastFires++
                    emitPowerSave()
                }
            }
            powerReceiver = receiver
            ContextCompat.registerReceiver(
                context,
                receiver,
                IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )

            val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) {
                    observerFires++
                    emitPowerSave()
                }
            }
            powerObserver = observer
            context.contentResolver.registerContentObserver(
                Settings.Global.getUriFor(SETTING_LOW_POWER),
                false,
                observer,
            )
        }

        override fun onCancel(arguments: Any?) {
            powerReceiver?.let {
                runCatching { applicationContext?.unregisterReceiver(it) }
            }
            powerObserver?.let {
                applicationContext?.contentResolver?.unregisterContentObserver(it)
            }
            powerReceiver = null
            powerObserver = null
            powerSink = null
        }
    }

    /** Emits only on an actual transition, whichever source noticed it. */
    private fun emitPowerSave() {
        val now = isPowerSaveMode()
        if (now == lastPowerSaveMode) return
        lastPowerSaveMode = now
        powerSink?.success(now)
    }

    /** Ambient needs its own sink, so it gets its own handler. */
    private val ambientStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            ambientSink = events
        }

        override fun onCancel(arguments: Any?) {
            ambientSink = null
        }
    }

    companion object {
        /** SOURCE_ROTARY_ENCODER, inlined so no androidx.wear dependency is needed. */
        private const val SOURCE_ROTARY_ENCODER = 0x00400000

        /**
         * `Settings.Global.LOW_POWER`, which is `@hide` in the SDK.
         *
         * Global settings can be read by name, and this is the key that
         * `adb shell settings put global low_power 1` writes. Used only as a
         * secondary diagnostic - `PowerManager.isPowerSaveMode` remains the
         * value Sizzle actually reports.
         */
        private const val SETTING_LOW_POWER = "low_power"

        /** Live instances, so the host activity can forward without a binding. */
        private val instances = mutableSetOf<SizzleWearablePlugin>()

        /**
         * Forward a generic motion event from the host activity.
         *
         * @return true when the event was rotary scroll and has been consumed.
         */
        @JvmStatic
        fun onGenericMotionEvent(event: MotionEvent?): Boolean {
            if (event == null) return false
            if (event.action != MotionEvent.ACTION_SCROLL) return false
            if (!event.isFromSource(SOURCE_ROTARY_ENCODER)) return false

            // Every sample this event carries, not just the newest. A batched
            // event whose history is ignored silently loses rotation, and it
            // loses more of it the faster the crown is turned - which reads to
            // the player as the control going numb at speed.
            val historySize = event.historySize
            val historical = FloatArray(historySize) { i ->
                event.getHistoricalAxisValue(MotionEvent.AXIS_SCROLL, i)
            }
            val scroll = RotaryScroll.sumAxis(
                event.getAxisValue(MotionEvent.AXIS_SCROLL),
                historical,
            )
            if (scroll == 0f) return false

            val resolution = scrollResolution(event)
            synchronized(instances) {
                instances.forEach {
                    it.emitRotary(
                        scroll = scroll,
                        resolution = resolution,
                        deviceId = event.deviceId,
                        deviceName = event.device?.name,
                        samples = 1 + historySize,
                        eventTimeMs = event.eventTime,
                    )
                }
            }
            return true
        }

        /**
         * Forward an ambient mode transition from the host activity.
         *
         * Only the transition is forwarded - Sizzle uses it to pause, not to
         * render an ambient screen, so burn-in and low-bit details would go
         * unused.
         */
        @JvmStatic
        fun onAmbientChanged(isAmbient: Boolean) {
            synchronized(instances) {
                instances.forEach { it.ambientSink?.success(isAmbient) }
            }
        }

        /**
         * The device's own reported resolution for the scroll axis, in units
         * per radian, or null when it publishes none.
         *
         * `InputDevice.MotionRange.getResolution` is documented as "units per
         * millimeter, or units per radian for rotational axes", so dividing raw
         * scroll by it should yield radians. That `AXIS_SCROLL` on a rotary
         * encoder counts as a rotational axis for that purpose is a reading of
         * the docs rather than something they state - `rotaryDiagnostics` and
         * the example app's CAL mode exist to check it against real hardware,
         * where one physical revolution should come out at 2*pi.
         *
         * **A negative resolution is valid and must not be discarded.** Measured,
         * a Pixel Watch 3 crown reports `-0.791` and a Galaxy Watch5 touch bezel
         * `+4.774`. Rejecting the negative one - which this did - threw away the
         * crown's only proportional signal and left it on a flat per-event
         * fallback, so its steering tracked how *long* the crown was turned
         * rather than how *far*. Only NaN and exactly zero are unusable.
         *
         * The sign is passed through rather than interpreted. It is tempting to
         * read it as the device declaring its direction convention, but the
         * measurements say otherwise: the Watch5 is the reversed one and its
         * resolution is positive. So the sign of rotation lives in the scroll
         * value, Dart scales by the magnitude, and [Rotary.invert] stays the
         * knob for direction.
         */
        private fun scrollResolution(event: MotionEvent): Double? {
            val device = event.device ?: return null
            val range = device.getMotionRange(
                MotionEvent.AXIS_SCROLL,
                SOURCE_ROTARY_ENCODER,
            ) ?: return null
            val resolution = range.resolution
            if (resolution.isNaN() || resolution == 0f) return null
            return resolution.toDouble()
        }
    }

    // --------------------------------------------------------------- engine

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "sizzle_wearable")
        methodChannel.setMethodCallHandler(this)
        rotaryChannel = EventChannel(binding.binaryMessenger, "sizzle_wearable/rotary")
        rotaryChannel.setStreamHandler(this)
        ambientChannel = EventChannel(binding.binaryMessenger, "sizzle_wearable/ambient")
        ambientChannel.setStreamHandler(ambientStreamHandler)
        powerChannel = EventChannel(binding.binaryMessenger, "sizzle_wearable/power")
        powerChannel.setStreamHandler(powerStreamHandler)
        synchronized(instances) { instances.add(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        synchronized(instances) { instances.remove(this) }
        methodChannel.setMethodCallHandler(null)
        rotaryChannel.setStreamHandler(null)
        ambientChannel.setStreamHandler(null)
        powerStreamHandler.onCancel(null)
        powerChannel.setStreamHandler(null)
        applicationContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    // --------------------------------------------------------------- rotary

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        rotarySink = events
    }

    override fun onCancel(arguments: Any?) {
        rotarySink = null
    }

    /**
     * Report one rotary event to Dart.
     *
     * Deliberately raw: the unit decision lives in Dart, where it is reachable
     * from a test and tunable per device without a native build.
     */
    private fun emitRotary(
        scroll: Float,
        resolution: Double?,
        deviceId: Int,
        deviceName: String?,
        samples: Int,
        eventTimeMs: Long,
    ) {
        val sink = rotarySink ?: return
        val payload = mutableMapOf<String, Any>(
            "scroll" to scroll.toDouble(),
            "deviceId" to deviceId,
            "samples" to samples,
            "eventTimeMs" to eventTimeMs,
        )
        if (resolution != null) payload["resolution"] = resolution
        if (deviceName != null) payload["deviceName"] = deviceName
        scrollFactor()?.let { payload["scrollFactor"] = it }
        sink.success(payload)
    }

    /**
     * `ViewConfiguration.getScaledVerticalScrollFactor`, reported for
     * diagnostics only.
     *
     * This is what Google's own rotary samples multiply `AXIS_SCROLL` by, but
     * it converts scroll units to *pixels of list scroll* - it is
     * `listPreferredItemHeight` from the theme and carries no angular
     * information whatsoever. Recorded so a device's numbers can be compared
     * against those samples, never used to derive an angle.
     */
    private fun scrollFactor(): Double? {
        val context = applicationContext ?: return null
        return android.view.ViewConfiguration.get(context)
            .scaledVerticalScrollFactor
            .toDouble()
    }

    // -------------------------------------------------------------- methods

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "isSupported" -> result.success(isWatch())
            "isRound" -> result.success(isRound())
            "isPowerSaveMode" -> result.success(isPowerSaveMode())
            "powerDiagnostics" -> result.success(
                mapOf(
                    "isPowerSaveMode" to isPowerSaveMode(),
                    "platformFlag" to platformPowerSaveFlag(),
                    "lowPowerSetting" to lowPowerSetting(),
                    "broadcastFires" to broadcastFires,
                    "observerFires" to observerFires,
                ),
            )
            "rotaryDiagnostics" -> result.success(rotaryDiagnostics())
            "audioProperties" -> result.success(audioProperties())
            "displayInfo" -> result.success(displayInfo())
            "deviceInfo" -> result.success(deviceInfo())
            "setKeepScreenOn" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                setKeepScreenOn(enabled)
                result.success(null)
            }
            "setSwipeToDismissEnabled" -> {
                SizzleWearableActivity.swipeToDismissEnabled =
                    call.argument<Boolean>("enabled") ?: true
                // The static flag alone is not enough on API 33+: the back
                // callback has to be registered or unregistered to match.
                (activity as? SizzleWearableActivity)?.let {
                    it.runOnUiThread { it.applySwipeToDismissState() }
                }
                result.success(null)
            }
            "setGestureExclusionEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                SizzleWearableActivity.gestureExclusionEnabled = enabled
                applyGestureExclusion(enabled)
                result.success(null)
            }
            "setFrameRate" -> {
                val fps = (call.argument<Double>("fps") ?: 0.0).toFloat()
                result.success(setFrameRate(fps))
            }
            "clearFrameRate" -> {
                setFrameRate(0f)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * What every rotary encoder attached to this device publishes about itself.
     *
     * Answerable before a single event arrives, which is the point: it
     * separates "this device publishes no usable scroll resolution" from "this
     * device is not emitting rotary events at all". Those two produce identical
     * silence in a stream-only diagnostic and want completely different fixes.
     *
     * `scrollFactor` is included for comparison against Google's rotary samples
     * only - see [scrollFactor].
     */
    private fun rotaryDiagnostics(): Map<String, Any?> {
        val devices = mutableListOf<Map<String, Any?>>()
        for (id in android.view.InputDevice.getDeviceIds()) {
            val device = android.view.InputDevice.getDevice(id) ?: continue
            if ((device.sources and SOURCE_ROTARY_ENCODER) != SOURCE_ROTARY_ENCODER) {
                continue
            }
            val range = device.getMotionRange(
                MotionEvent.AXIS_SCROLL,
                SOURCE_ROTARY_ENCODER,
            )
            devices.add(
                mapOf(
                    "id" to id,
                    "name" to device.name,
                    "sources" to device.sources,
                    // Null throughout rather than absent when the device
                    // publishes no AXIS_SCROLL range at all: "asked, got
                    // nothing" is a finding, and squashing it into a missing
                    // key makes it look like a plugin omission.
                    "min" to range?.min?.toDouble(),
                    "max" to range?.max?.toDouble(),
                    "resolution" to range?.resolution?.toDouble(),
                    "flat" to range?.flat?.toDouble(),
                    "fuzz" to range?.fuzz?.toDouble(),
                ),
            )
        }
        return mapOf(
            "devices" to devices,
            "scrollFactor" to scrollFactor(),
        )
    }

    private fun isWatch(): Boolean {
        val context = applicationContext ?: return false
        return context.packageManager.hasSystemFeature(PackageManager.FEATURE_WATCH)
    }

    private fun isRound(): Boolean {
        val context = applicationContext ?: return false
        return context.resources.configuration.isScreenRound
    }

    /**
     * Build identifiers, for keeping a per-device feature matrix.
     *
     * Wear behaviour varies between devices that look identical on paper -
     * whether a frame rate request is honoured is the obvious case - so the
     * only way to build a useful matrix is to record exactly which device
     * produced each result.
     */
    private fun deviceInfo(): Map<String, Any> {
        val context = applicationContext
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "product" to Build.PRODUCT,
            "hardware" to Build.HARDWARE,
            "androidRelease" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "fingerprint" to Build.FINGERPRINT,
            "isWatch" to (
                context?.packageManager
                    ?.hasSystemFeature(PackageManager.FEATURE_WATCH) ?: false
                ),
        )
    }

    /**
     * Whether the device is in a battery-saving state.
     *
     * The union of two signals, because on Wear OS they diverge. Stock
     * Android backs `PowerManager.isPowerSaveMode` with
     * `Settings.Global.low_power`, so there the two always agree and the
     * union costs nothing. On a Pixel Watch 3 writing `low_power` does *not*
     * move the platform flag, so reading only the flag misses the change
     * entirely.
     *
     * Note this still cannot see Wear's own "Battery Saver Mode" - see
     * [powerDiagnostics].
     */
    private fun isPowerSaveMode(): Boolean {
        val context = applicationContext ?: return false
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return (power?.isPowerSaveMode ?: false) || lowPowerSetting() == 1
    }

    /** `PowerManager.isPowerSaveMode` alone, for comparison with the setting. */
    private fun platformPowerSaveFlag(): Boolean {
        val context = applicationContext ?: return false
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return power?.isPowerSaveMode ?: false
    }

    /**
     * The raw `Settings.Global.LOW_POWER` value, or -1 if unreadable.
     *
     * Reported alongside [isPowerSaveMode] purely as a diagnostic: if a
     * device's battery saver toggle moves one and not the other, this is what
     * shows it. Wear OS has its own power modes that do not necessarily map
     * onto the platform flag.
     */
    private fun lowPowerSetting(): Int {
        val context = applicationContext ?: return -1
        return runCatching {
            Settings.Global.getInt(context.contentResolver, SETTING_LOW_POWER)
        }.getOrDefault(-1)
    }

    private fun setKeepScreenOn(enabled: Boolean) {
        val current = activity ?: return
        current.runOnUiThread {
            if (enabled) {
                current.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                current.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    private fun applyGestureExclusion(enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val current = activity ?: return
        current.runOnUiThread {
            val root: View = current.window.decorView
            root.systemGestureExclusionRects = if (enabled) {
                listOf(Rect(0, 0, root.width, root.height))
            } else {
                emptyList()
            }
        }
    }

    private fun audioProperties(): Map<String, Int>? {
        val context = applicationContext ?: return null
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return null
        val rate = audio
            .getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
            ?.toIntOrNull() ?: return null
        val frames = audio
            .getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)
            ?.toIntOrNull() ?: return null
        return mapOf("sampleRate" to rate, "framesPerBuffer" to frames)
    }

    /**
     * What the display says it can do.
     *
     * Informational only: `supportedRefreshRates` does NOT predict whether a
     * rate request will be honoured. A Pixel Watch 3 reports only 60 and yet
     * honours a 30fps request; a TicWatch Pro 5 reports the same and ignores
     * it. Sizzle settles the question by measuring the real frame cadence.
     */
    private fun displayInfo(): Map<String, Any> {
        val current = activity ?: return emptyMap()
        @Suppress("DEPRECATION")
        val disp = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            current.display
        } else {
            current.windowManager.defaultDisplay
        }
        val modes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            disp?.supportedModes?.map { it.refreshRate } ?: emptyList()
        } else {
            emptyList()
        }
        return mapOf(
            "refreshRate" to (disp?.refreshRate ?: 0f),
            "supportedRefreshRates" to modes,
        )
    }

    /**
     * Ask the display to present at [fps]; 0 releases the request.
     *
     * Ported from the proven framerate experiment. Two levers are applied
     * together because neither is reliable alone:
     *
     *  1. `WindowManager.LayoutParams.preferredRefreshRate` (API 23+) - a
     *     polite window-level hint the platform may ignore.
     *  2. `Surface.setFrameRate` (API 30+) on Flutter's own SurfaceView - the
     *     one that actually drops a Wear panel to 30Hz where it works at all.
     *
     * @return true if at least one lever was applied. Says nothing about
     *         whether the panel obeyed - that is measured, never assumed.
     */
    private fun setFrameRate(fps: Float): Boolean {
        val current = activity ?: return false
        var applied = false

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            current.runOnUiThread {
                val lp = current.window.attributes
                lp.preferredRefreshRate = if (fps > 0f) fps else 0f
                current.window.attributes = lp
            }
            applied = true
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val surface = findFlutterSurface(current.window.decorView)
            if (surface != null && surface.isValid) {
                current.runOnUiThread {
                    if (fps > 0f) {
                        surface.setFrameRate(
                            fps,
                            Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
                        )
                    } else {
                        surface.setFrameRate(
                            0f,
                            Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                        )
                    }
                }
                applied = true
            }
        }

        return applied
    }

    /**
     * Depth-first search for Flutter's SurfaceView. Returns null when Flutter
     * renders into a TextureView instead, in which case only the window hint
     * is available.
     */
    private fun findFlutterSurface(view: View): Surface? {
        if (view is SurfaceView) {
            return view.holder?.surface
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findFlutterSurface(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }
}
