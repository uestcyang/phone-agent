package org.phoneagent.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent


class HeartbeatAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        DeviceBridge.reconcile(context)
        context.sendBroadcast(
            Intent(HeartbeatBridgeRelayReceiver.ACTION_TICK).setPackage(context.packageName)
        )
        HeartbeatAlarm.schedule(context)
    }
}
