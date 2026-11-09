package io.paraplu.sizzle_wearable

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.wear.remote.interactions.RemoteActivityHelper
import androidx.wear.widget.ConfirmationOverlay

/**
 * Opens a web page on the phone paired with this watch.
 *
 * A watch has no browser to hand a page to, so Wear OS's answer is a remote
 * activity: [RemoteActivityHelper] sends a `VIEW` intent to the phone, which
 * opens it in its own browser. The result says whether the phone accepted
 * the intent, not whether the page loaded; it fails when no phone is
 * connected, and on a watch paired with an iPhone it is not supported.
 *
 * On success the standard "open on phone" animation plays on the watch
 * ([ConfirmationOverlay.OPEN_ON_PHONE_ANIMATION]), which is what the Wear OS
 * guidelines ask an app to show, because the page appears on another device.
 */
internal class OpenOnPhone(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())

    /**
     * Send [url] to the phone and call [done] on the main thread with whether
     * it was accepted. [activity] is where the confirmation is drawn; with
     * none, or with [confirm] false, nothing is drawn.
     */
    fun open(url: String, activity: Activity?, confirm: Boolean, done: (Boolean) -> Unit) {
        val intent = Intent(Intent.ACTION_VIEW)
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .setData(Uri.parse(url))
        val future = try {
            RemoteActivityHelper(context).startRemoteActivity(intent)
        } catch (e: Exception) {
            done(false)
            return
        }
        future.addListener({
            val opened = try {
                future.get()
                true
            } catch (e: Exception) {
                false
            }
            if (opened && confirm && activity != null && !activity.isFinishing) {
                ConfirmationOverlay()
                    .setType(ConfirmationOverlay.OPEN_ON_PHONE_ANIMATION)
                    .showOn(activity)
            }
            done(opened)
        }, { main.post(it) })
    }
}
