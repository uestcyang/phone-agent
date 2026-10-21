package org.phoneagent.app

import android.app.ForegroundServiceStartNotAllowedException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log


class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "PhoneAgentBoot"


        val WAKE_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )


        fun reviveWithFallback(context: Context, tag: String) {
            try {
                KeepAliveForegroundService.ensureRunning(context)
                KeepAliveWatchdog.schedule(context)
                HeartbeatAlarm.schedule(context)
                Log.i(TAG, "[$tag] ensureRunning ok")
            } catch (e: Exception) {
                val notAllowed = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    e is ForegroundServiceStartNotAllowedException
                Log.w(TAG, "[$tag] ensureRunning failed (fgsNotAllowed=$notAllowed), fall back to one-shot job", e)
                KeepAliveReviveJobService.enqueueOneShot(context)
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action !in WAKE_ACTIONS) return
        Log.i(TAG, "main-process receiver woke on $action")
        reviveWithFallback(context, "main:$action")


        if (action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            AdbWifiSelfEnabler.enableOnBoot(context)
        }
    }
}
