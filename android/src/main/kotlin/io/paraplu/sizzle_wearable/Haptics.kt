package io.paraplu.sizzle_wearable

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.plugin.common.MethodCall
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The device vibrator, behind the Dart `Haptics` class.
 *
 * Dart chooses which tier of an effect to play from [info], so this side only
 * reports what the vibrator can do and plays exactly what it is handed. Every
 * call is wrapped: a vibrator that refuses an effect costs a missed buzz,
 * never a crash.
 */
internal class Haptics(context: Context) {
    private val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        context.getSystemService(VibratorManager::class.java)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    /**
     * Keys: `hasVibrator`, `amplitudeControl`, `presets` (the supported
     * `VibrationEffect.EFFECT_*` ids), `primitives` (supported
     * `Composition.PRIMITIVE_*` id to length in ms, or null below API 31) and
     * `resonantHz` (absent when the motor does not report it).
     *
     * Presets and primitives are only queryable from API 30, and Wear OS 3 is
     * API 30, so below that both are reported empty rather than guessed.
     *
     * **Every optional query is wrapped, and an API level is not proof that a
     * method exists.** `getResonantFrequency` is documented from API 31, yet a
     * TicWatch Pro 5 on API 33 threw `NoSuchMethodError` for it (2026-10-19),
     * and an uncaught throw here kills the app during loading. So it is gated at
     * API 34 and each block is a `runCatching` — which catches `Error` as well as
     * `Exception` — and a failed block just leaves its key at the default.
     */
    fun info(): Map<String, Any?> {
        val v = vibrator
        if (v == null || runCatching { v.hasVibrator() }.getOrDefault(false).not()) {
            return mapOf("hasVibrator" to false)
        }
        val out = mutableMapOf<String, Any?>(
            "hasVibrator" to true,
            "amplitudeControl" to runCatching {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && v.hasAmplitudeControl()
            }.getOrDefault(false),
            "presets" to emptyList<Int>(),
            "primitives" to emptyMap<Int, Int?>(),
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) runCatching {
            val support = v.areEffectsSupported(*PRESETS)
            out["presets"] = PRESETS.filterIndexed { i, _ ->
                support[i] == Vibrator.VIBRATION_EFFECT_SUPPORT_YES
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) runCatching {
            val supported = v.arePrimitivesSupported(*PRIMITIVES)
            val durations = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                runCatching { v.getPrimitiveDurations(*PRIMITIVES) }.getOrNull()
            } else {
                null
            }
            val primitives = mutableMapOf<Int, Int?>()
            PRIMITIVES.forEachIndexed { i, id ->
                if (supported[i]) primitives[id] = durations?.get(i)
            }
            out["primitives"] = primitives
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) runCatching {
            val hz = v.resonantFrequency
            if (!hz.isNaN()) out["resonantHz"] = hz.toDouble()
        }
        return out
    }

    /**
     * Every vibrator call runs here, one at a time and in order, **never on the
     * thread that called in**.
     *
     * Since Flutter 3.29 an Android app runs its Dart code on the platform's
     * main thread, so a method-channel handler shares a thread with the game's
     * frames. One `vibrate()` measured 10.9 ms there on a Galaxy Watch5
     * (2026-10-19), most of a 16.7 ms frame, and a buzz fired on the frame a
     * race starts visibly stalled the animation on all three watches. Queued on
     * one thread, a play and a following cancel still reach the vibrator in the
     * order Dart sent them.
     */
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "sizzle-haptics")
    }

    /** Plays the tier Dart encoded in `HapticsInfo.encode`. */
    fun play(call: MethodCall) {
        val v = vibrator ?: return
        // Built here, where the call's arguments are, and only handed on.
        val effect = runCatching { build(call) }.getOrNull() ?: return
        submit {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                v.vibrate(
                    effect,
                    VibrationAttributes.createForUsage(VibrationAttributes.USAGE_MEDIA),
                )
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(effect, GAME_AUDIO)
            }
        }
    }

    fun cancel() {
        val v = vibrator ?: return
        submit { v.cancel() }
    }

    /** Stops the worker. The plugin calls it when the engine detaches. */
    fun dispose() {
        worker.shutdown()
    }

    private fun submit(task: () -> Unit) {
        runCatching { worker.execute { runCatching(task) } }
    }

    private fun build(call: MethodCall): VibrationEffect? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        return when (call.argument<String>("kind")) {
            "predefined" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
                VibrationEffect.createPredefined(call.argument<Number>("id")!!.toInt())
            }
            "composition" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
                val ids = numbers(call, "ids")
                val scales = numbers(call, "scales")
                val delays = numbers(call, "delays")
                if (ids.isEmpty()) return null
                val composition = VibrationEffect.startComposition()
                ids.forEachIndexed { i, id ->
                    composition.addPrimitive(
                        id.toInt(),
                        scales[i].toFloat(),
                        delays[i].toInt(),
                    )
                }
                composition.compose()
            }
            "waveform" -> {
                val timings = numbers(call, "timings").map { it.toLong() }.toLongArray()
                val amplitudes = numbers(call, "amplitudes").map { it.toInt() }.toIntArray()
                if (timings.isEmpty() || timings.all { it == 0L }) return null
                VibrationEffect.createWaveform(
                    timings,
                    amplitudes,
                    call.argument<Number>("repeat")?.toInt() ?: -1,
                )
            }
            else -> null
        }
    }

    private fun numbers(call: MethodCall, key: String): List<Number> =
        call.argument<List<Number>>(key) ?: emptyList()

    private companion object {
        /** EFFECT_CLICK, EFFECT_DOUBLE_CLICK, EFFECT_TICK, EFFECT_HEAVY_CLICK. */
        val PRESETS = intArrayOf(0, 1, 2, 5)

        /** PRIMITIVE_CLICK through PRIMITIVE_LOW_TICK. */
        val PRIMITIVES = intArrayOf(1, 2, 3, 4, 5, 6, 7, 8)

        /**
         * Below API 33 a vibration's usage comes from audio attributes, and
         * `USAGE_GAME` maps to the media vibration usage.
         */
        val GAME_AUDIO: AudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_GAME)
            .build()
    }
}
