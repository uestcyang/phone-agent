package org.phoneagent.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log


class WidgetTokenSelfTestReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "org.phoneagent.app.WIDGET_TOKEN_SELFTEST"
        private const val TAG = "WidgetTokenSelfTest"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_LISTEN_TOKEN = "flutter.widget_listen_token"
        private const val KEY_FETCH_STATE = "flutter.widget_fetch_state"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION) return
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val token = prefs.getString(KEY_LISTEN_TOKEN, null)
        val fetchState = prefs.getString(KEY_FETCH_STATE, null)
        if (token.isNullOrEmpty()) {
            Log.i(TAG, "token=<empty/null> fetchState=$fetchState")
        } else {
            val prefix = token.substring(0, minOf(12, token.length))
            Log.i(TAG, "token_prefix12=$prefix token_len=${token.length} fetchState=$fetchState")
        }
    }
}
