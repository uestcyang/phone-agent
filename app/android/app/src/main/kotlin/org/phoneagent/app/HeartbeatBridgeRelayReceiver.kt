package org.phoneagent.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent


class HeartbeatBridgeRelayReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_TICK = "org.phoneagent.app.HEARTBEAT_TICK_RELAY"
        const val ACTION_NETWORK_AVAILABLE = "org.phoneagent.app.HEARTBEAT_NETWORK_RELAY"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            ACTION_TICK -> HeartbeatBridge.tick(context)
            ACTION_NETWORK_AVAILABLE -> HeartbeatBridge.notifyNetworkChanged(context)
        }
    }
}
