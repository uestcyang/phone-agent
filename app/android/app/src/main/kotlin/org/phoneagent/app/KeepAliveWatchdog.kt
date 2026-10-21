package org.phoneagent.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock


object KeepAliveWatchdog {
    private const val INTERVAL_MS = 45_000L
    private const val REQUEST_CODE = 9001

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, KeepAliveWatchdogReceiver::class.java)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }


    private const val SELF_HEAL_DELAY_MS = 5_000L

    fun schedule(context: Context) = scheduleAt(context, INTERVAL_MS)


    fun scheduleOneShotSoon(context: Context) = scheduleAt(context, SELF_HEAL_DELAY_MS)

    private fun scheduleAt(context: Context, delayMs: Long) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val triggerAt = SystemClock.elapsedRealtime() + delayMs
        try {
            am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pendingIntent(context))
        } catch (_: SecurityException) {

            am.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pendingIntent(context))
        }
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent(context))
    }
}
