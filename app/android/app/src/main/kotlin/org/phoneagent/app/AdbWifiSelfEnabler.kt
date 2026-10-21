package org.phoneagent.app

import android.content.Context
import android.provider.Settings
import android.util.Log


object AdbWifiSelfEnabler {
    private const val TAG = "PhoneAgentAdbWifi"


    private const val KEY_ADB_WIFI_ENABLED = "adb_wifi_enabled"


    private val ALLOWED_KEYS = setOf(KEY_ADB_WIFI_ENABLED)


    private val FORBIDDEN_SUBSTR = listOf("proxy")


    fun enableOnBoot(context: Context) {
        writeSecureGlobalInt(context, KEY_ADB_WIFI_ENABLED, 1)
    }


    private fun writeSecureGlobalInt(context: Context, key: String, value: Int) {
        val k = key.lowercase()
        if (FORBIDDEN_SUBSTR.any { k.contains(it) }) {

            Log.e(TAG, "REFUSED forbidden key '$key' (proxy-class keys are hard-banned, see class doc)")
            return
        }
        if (key !in ALLOWED_KEYS) {
            Log.e(TAG, "REFUSED key '$key' not in whitelist $ALLOWED_KEYS (see class doc)")
            return
        }
        try {
            val cr = context.contentResolver
            val before = Settings.Global.getInt(cr, key, -1)
            Settings.Global.putInt(cr, key, value)
            val after = Settings.Global.getInt(cr, key, -1)
            Log.i(TAG, "wrote Settings.Global[$key] $before -> $after (target=$value)")
        } catch (e: SecurityException) {
            Log.w(TAG, "no WRITE_SECURE_SETTINGS yet, skip [$key]=$value (grant via Mac pm grant)", e)
        } catch (e: Exception) {
            Log.w(TAG, "failed writing [$key]=$value", e)
        }
    }
}
