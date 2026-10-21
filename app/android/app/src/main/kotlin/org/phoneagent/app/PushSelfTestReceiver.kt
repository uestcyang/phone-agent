package org.phoneagent.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log


class PushSelfTestReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "org.phoneagent.app.PUSH_SELFTEST"
        private const val TAG = "PushSelfTest"
        private val ALLOWED_AGENTS = setOf("agent_b", "agent_a", "agent_c", "agent_d", "agent_e", "agent_g", "demo_legacy")
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION) return
        val requested = intent.getStringExtra("agent") ?: "agent_c"
        val agentId = if (requested in ALLOWED_AGENTS) requested else "agent_c"
        val silent = intent.getBooleanExtra("silent", false)
        val level = intent.getStringExtra("level")
        val body = "验收自检 · silent=$silent level=$level · 修复后基线测试消息"
        Log.i(TAG, "selftest post agent=$agentId silent=$silent level=$level")
        PushNotifications.post(
            context = context.applicationContext,
            agentId = agentId,
            displayName = agentId,
            body = body,
            silent = silent,
        )
    }
}
