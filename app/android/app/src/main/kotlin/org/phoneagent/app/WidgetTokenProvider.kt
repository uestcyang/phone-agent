package org.phoneagent.app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Bundle


class WidgetTokenProvider : ContentProvider() {
    companion object {
        const val AUTHORITY = "org.phoneagent.app.widgettoken"
        val CONTENT_URI: Uri = Uri.parse("content://$AUTHORITY")
        const val METHOD_SET_TOKEN = "set_token"
        const val EXTRA_TOKEN = "token"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_LISTEN_TOKEN = "flutter.widget_listen_token"
    }

    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        if (method == METHOD_SET_TOKEN) {
            val token = arg ?: extras?.getString(EXTRA_TOKEN) ?: ""
            val prefs = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val edit = prefs?.edit()?.putString(KEY_LISTEN_TOKEN, token)


            extras?.getString("wallet_token")?.let {
                edit?.putString(WidgetIngress.WALLET_TOKEN_KEY, it)
            }
            val summary = extras?.getString("summary_url")
            val ack = extras?.getString("ack_url")
            if (WidgetIngress.trusted(summary, "/widget_summary", BuildConfig.WIDGET_SUMMARY_URL)) {
                edit?.putString(WidgetIngress.SUMMARY_KEY, summary)
            }
            if (WidgetIngress.trusted(ack, "/pai/ack", BuildConfig.PAI_ACK_URL)) {
                edit?.putString(WidgetIngress.ACK_KEY, ack)
            }
            edit?.commit()
        }
        return null
    }


    override fun query(
        uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?
    ): Int = 0
}
