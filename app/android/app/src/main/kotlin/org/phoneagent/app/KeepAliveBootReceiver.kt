package org.phoneagent.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log


class KeepAliveBootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "PhoneAgentBoot"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action !in BootReceiver.WAKE_ACTIONS) return
        Log.i(TAG, "keepalive-process receiver woke on $action")
        BootReceiver.reviveWithFallback(context, "keepalive:$action")
    }
}
