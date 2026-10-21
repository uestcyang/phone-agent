package org.phoneagent.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput


class ReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != PushNotifications.ACTION_REPLY) return
        val agentId = intent.getStringExtra(PushNotifications.EXTRA_AGENT_ID) ?: return
        val displayName = intent.getStringExtra(PushNotifications.EXTRA_AGENT_NAME) ?: agentId
        val text = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(PushNotifications.KEY_REPLY_TEXT)
            ?.toString()
            ?.trim()
        if (text.isNullOrEmpty()) return

        ReplyBridge.send(agentId, text)


        PushNotifications.post(context, agentId, displayName, text, fromUser = true)
    }
}
