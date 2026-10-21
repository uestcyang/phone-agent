package org.phoneagent.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlin.concurrent.thread


class ShizukuSelfTestReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "org.phoneagent.app.SHIZUKU_SELFTEST"


        const val ACTION_REQUEST_PERMISSION = "org.phoneagent.app.SHIZUKU_REQUEST_PERMISSION"
        private const val TAG = "ShizukuSelfTest"
        private const val REQ_CODE = 20260730
        @Volatile private var resultListenerInstalled = false
    }

    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            ACTION -> {
                Log.i(TAG, "=== self-test start ===")
                thread(name = "shizuku-selftest") { runSelfTest() }
            }
            ACTION_REQUEST_PERMISSION -> {
                Log.i(TAG, "=== requestPermission probe start ===")
                thread(name = "shizuku-reqperm") { runRequestPermissionProbe() }
            }
        }
    }

    private fun runRequestPermissionProbe() {
        val alive = try { rikka.shizuku.Shizuku.pingBinder() } catch (e: Throwable) { false }
        if (!alive) {
            Log.i(TAG, "requestPermission probe: binder not alive, abort")
            return
        }
        val rationale = try { rikka.shizuku.Shizuku.shouldShowRequestPermissionRationale() } catch (e: Throwable) {
            Log.i(TAG, "shouldShowRequestPermissionRationale threw: $e")
            false
        }
        Log.i(TAG, "shouldShowRequestPermissionRationale=$rationale")
        val listener = rikka.shizuku.Shizuku.OnRequestPermissionResultListener { code, grantResult ->
            Log.i(TAG, "requestPermission RESULT: requestCode=$code grantResult=$grantResult (GRANTED=${android.content.pm.PackageManager.PERMISSION_GRANTED})")
        }
        rikka.shizuku.Shizuku.addRequestPermissionResultListener(listener)
        try {
            rikka.shizuku.Shizuku.requestPermission(REQ_CODE)
            Log.i(TAG, "requestPermission($REQ_CODE) called without throwing, waiting for async result (or none)")
        } catch (e: Throwable) {
            Log.i(TAG, "requestPermission threw: $e")
        }
    }

    private fun runSelfTest() {
        val alive = try { rikka.shizuku.Shizuku.pingBinder() } catch (e: Throwable) { false }
        Log.i(TAG, "binderAlive=$alive")
        if (!alive) {
            Log.i(TAG, "=== self-test end (binder not alive, stop here) ===")
            return
        }
        val granted = try {
            rikka.shizuku.Shizuku.checkSelfPermission() == android.content.pm.PackageManager.PERMISSION_GRANTED
        } catch (e: Throwable) {
            Log.i(TAG, "checkSelfPermission threw: ${e.message}")
            false
        }
        val uid = try { rikka.shizuku.Shizuku.getUid() } catch (e: Throwable) { -1 }
        Log.i(TAG, "granted=$granted uid=$uid")
        if (!granted) {


            synchronized(this) {
                if (!resultListenerInstalled) {
                    resultListenerInstalled = true
                    rikka.shizuku.Shizuku.addRequestPermissionResultListener(
                        rikka.shizuku.Shizuku.OnRequestPermissionResultListener { code, grantResult ->
                            Log.i(TAG, "requestPermission RESULT: requestCode=$code grantResult=$grantResult (GRANTED=${android.content.pm.PackageManager.PERMISSION_GRANTED})")
                        }
                    )
                }
            }
            val rationale = try { rikka.shizuku.Shizuku.shouldShowRequestPermissionRationale() } catch (e: Throwable) { null }
            Log.i(TAG, "shouldShowRequestPermissionRationale=$rationale")
            try {
                rikka.shizuku.Shizuku.requestPermission(REQ_CODE)
                Log.i(TAG, "requestPermission($REQ_CODE) called without throwing")
            } catch (e: Throwable) {
                Log.i(TAG, "requestPermission threw: $e")
            }
            Log.i(TAG, "=== self-test end (no permission, stop here) ===")
            return
        }

        for (cmd in listOf("id", "getprop ro.build.version.sdk", "cat /data/system/packages.xml")) {
            val (result, error) = execOnce(cmd)
            if (error != null) {
                Log.i(TAG, "exec(\"$cmd\") FAILED: $error")
            } else {
                Log.i(TAG, "exec(\"$cmd\") -> exitCode=${result?.first} output=${result?.second?.take(300)}")
            }
        }
        Log.i(TAG, "=== self-test end ===")
    }


    private fun execOnce(cmd: String): Pair<Pair<Int, String>?, String?> {
        return try {
            Pair(ShizukuBridge.execForSelfTest(cmd), null)
        } catch (e: Throwable) {
            Pair(null, e.message ?: e.toString())
        }
    }
}
