package org.phoneagent.app

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import kotlin.concurrent.thread


object DeviceBridge {
    private const val TAG = "PhoneAgentDeviceBridge"
    private const val PREFS = "device_bridge_private"
    @Volatile private var worker: Thread? = null
    @Volatile private var active = false
    @Volatile private var child: Process? = null
    @Volatile private var connected = false
    @Volatile private var network = "none"
    @Volatile private var error = "unconfigured"
    @Volatile private var lastTunnelError = ""

    fun status(context: Context): JSONObject = JSONObject().apply {
        put("configured", context.getSharedPreferences(PREFS, 0).contains("config"))
        put("running", active && worker?.isAlive == true)
        put("child_alive", child?.isAlive == true)
        put("connected", connected)
        put("network", network)
        put("uid", android.os.Process.myUid())
        put("error", error)
        put("last_tunnel_error", lastTunnelError)
        put("network_binding", "native_system_route")
        put("vpn_bypass_forced", false)
        put("remote", DeviceBridgePolicy.REMOTE)
        put("egress_remote", DeviceBridgePolicy.EGRESS_REMOTE)
        put("global_network_changes", false)
    }

    @Synchronized fun configure(context: Context, text: String) {
        require(context.packageName == "org.phoneagent.app" && BuildConfig.PA_PUBLIC_ORIGIN.isNotEmpty())
        require(text.length <= 4096)
        val config = JSONObject(text)
        DeviceBridgePolicy.validate(config.getString("server"), config.getString("fingerprint"), config.getString("auth"), BuildConfig.PA_PUBLIC_ORIGIN)
        require(config.getBoolean("enabled"))

        require(worker?.isAlive != true) { "Disable and await stop before reconfiguration" }
        check(context.getSharedPreferences(PREFS, 0).edit().putString("config", text).commit())
        error = "configured"
        KeepAliveForegroundService.ensureRunning(context)
        reconcile(context)
    }

    @Synchronized fun reconcile(context: Context) {
        if (context.packageName != "org.phoneagent.app" || BuildConfig.PA_PUBLIC_ORIGIN.isEmpty()) return
        if (worker?.isAlive == true) return
        val configText = context.getSharedPreferences(PREFS, 0).getString("config", null) ?: return
        val config = try {
            JSONObject(configText).also {
                DeviceBridgePolicy.validate(it.getString("server"), it.getString("fingerprint"), it.getString("auth"), BuildConfig.PA_PUBLIC_ORIGIN)
            }
        } catch (_: Exception) { error = "invalid_config"; return }
        if (!config.optBoolean("enabled")) return
        active = true
        worker = thread(name = "owner-device-bridge", isDaemon = true) { run(context.applicationContext, config) }
    }

    @Synchronized fun stop(clear: Boolean = false, context: Context? = null) {
        if (clear && context != null) context.getSharedPreferences(PREFS, 0).edit().remove("config").commit()
        active = false
        connected = false
        child?.destroy()
        worker?.interrupt()
    }

    fun restartOwnedChild() { child?.destroy() }

    private fun run(context: Context, config: JSONObject) {
        try {
            val binary = File(context.applicationInfo.nativeLibraryDir, "libphonechisel.so")
            check(binary.isFile && binary.canExecute()) { "missing_binary" }
            val digest = MessageDigest.getInstance("SHA-256")
            binary.inputStream().use { input ->
                val buf = ByteArray(65536)
                while (true) { val n = input.read(buf); if (n < 0) break; digest.update(buf, 0, n) }
            }
            check(digest.digest().joinToString("") { "%02x".format(it) } == DeviceBridgePolicy.SHA256) { "binary_hash" }
            var backoff = 3000L
            while (active && !Thread.currentThread().isInterrupted) {
                error = "connecting"
                val builder = ProcessBuilder(binary.absolutePath, "client", "--fingerprint", config.getString("fingerprint"),
                    "--keepalive", "25s",
                    "--min-retry-interval", "3s", "--max-retry-interval", "60s", config.getString("server"),
                    DeviceBridgePolicy.REMOTE, DeviceBridgePolicy.EGRESS_REMOTE)
                    .redirectErrorStream(true)
                val env = builder.environment()
                listOf("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy").forEach { env.remove(it) }
                env["AUTH"] = config.getString("auth")
                env["SSL_CERT_DIR"] = "/apex/com.android.conscrypt/cacerts"
                val process = builder.start()
                child = process
                try {
                    process.inputStream.bufferedReader().useLines { lines -> lines.forEach { line ->

                    when {
                        line.contains("Connected (Latency") -> { connected = true; error = "none"; network = "native_system_route"; backoff = 3000L; Log.i(TAG, "connected public transport") }
                        line.contains("Connection error") || line.contains("Disconnected") -> {
                            connected = false; error = "tunnel_retry"
                            lastTunnelError = line.substringAfter("Connection error:", "disconnected")
                                .replace(config.getString("auth"), "[redacted]")
                                .replace(config.getString("auth").substringAfter(":"), "[redacted]").take(240)
                            Log.w(TAG, "tunnel retry: $lastTunnelError")
                        }
                    }
                    } }
                    process.waitFor()
                } catch (e: java.io.IOException) {
                    error = "child_stream_closed"
                    Log.w(TAG, "owned child stream closed; retrying")
                } finally {
                    process.destroy()
                    connected = false
                    child = null
                }
                if (active) { Thread.sleep(backoff); backoff = (backoff * 2).coerceAtMost(60000L) }
            }
        } catch (e: Exception) {
            error = if (e.message == "missing_binary" || e.message == "binary_hash") e.message!! else "bridge_stopped"
            Log.w(TAG, "bridge stopped: $error (${e.javaClass.simpleName})")
        } finally {
            child?.destroy(); child = null
            connected = false
            active = false
        }
    }

}
