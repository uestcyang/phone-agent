package org.phoneagent.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File


open class PrefsAuditReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_MAIN = "org.phoneagent.app.PREFS_AUDIT_MAIN"
        const val ACTION_KEEPALIVE = "org.phoneagent.app.PREFS_AUDIT_KEEPALIVE"
        private const val TAG = "PrefsAudit"
        private const val PREFS_NAME = "FlutterSharedPreferences"


        private const val LEGACY_BG = "flutter.chat_background_path"
        private const val LEGACY_AVATAR_PREFIX = "flutter.agent_avatar_path_"


        private const val SENTINEL = "flutter.audit_sentinel"

        private const val CUSTOM_DIR = "phone_agent_customization"
        private const val AUDIT_FILE = "audit_probe.txt"


        private fun customDir(context: Context): File =
            File(context.getDir("flutter", Context.MODE_PRIVATE), CUSTOM_DIR)
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val who = when (action) {
            ACTION_MAIN -> "main"
            ACTION_KEEPALIVE -> "keepalive"
            else -> return
        }
        val pid = android.os.Process.myPid()
        val ctx = context.applicationContext
        val prefs = ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        when (intent.getStringExtra("op") ?: "read") {
            "write" -> {
                val stamp = System.currentTimeMillis().toString()


                prefs.edit().putString("$SENTINEL.$who", stamp).commit()
                var fileOk = "n/a"
                if (who == "main") {
                    fileOk = try {
                        val dir = customDir(ctx)
                        dir.mkdirs()
                        File(dir, AUDIT_FILE).writeText(stamp)
                        "written"
                    } catch (e: Exception) {
                        "err:${e.javaClass.simpleName}"
                    }
                }
                Log.i(TAG, "[$who pid=$pid] WROTE sentinel=$stamp auditFile=$fileOk")
            }
            else -> {
                val all = prefs.all
                val avatarKeys = all.keys.filter { it.startsWith(LEGACY_AVATAR_PREFIX) }.sorted()
                val auditFile = File(customDir(ctx), AUDIT_FILE)
                val bgFile = File(customDir(ctx), "chat_bg.jpg")
                val avatarDir = File(customDir(ctx), "avatars")
                val avatarFiles = (avatarDir.listFiles()?.map { it.name } ?: emptyList()).sorted()

                Log.i(
                    TAG,
                    "[$who pid=$pid] PREFS totalKeys=${all.size} " +
                        "legacyBg=${if (all.containsKey(LEGACY_BG)) "present" else "ABSENT"} " +
                        "legacyAvatarKeys=${avatarKeys.size}$avatarKeys " +
                        "sentinel.main=${all["$SENTINEL.main"] ?: "ABSENT"} " +
                        "sentinel.keepalive=${all["$SENTINEL.keepalive"] ?: "ABSENT"}"
                )
                Log.i(
                    TAG,
                    "[$who pid=$pid] FILES auditProbe=${if (auditFile.exists()) "present" else "ABSENT"} " +
                        "chat_bg.jpg=${if (bgFile.exists()) "${bgFile.length()}B" else "ABSENT"} " +
                        "avatarFiles=${avatarFiles.size}$avatarFiles"
                )
            }
        }
    }
}


class PrefsAuditKeepaliveReceiver : PrefsAuditReceiver()
