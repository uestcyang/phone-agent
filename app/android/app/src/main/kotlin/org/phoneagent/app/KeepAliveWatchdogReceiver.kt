package org.phoneagent.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent


class KeepAliveWatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        KeepAliveForegroundService.ensureRunning(context)
        KeepAliveWatchdog.schedule(context)
        HeartbeatAlarm.schedule(context)
    }
}
