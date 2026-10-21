package org.phoneagent.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel


object HeartbeatBridge {
    const val CHANNEL = "org.phoneagent.app/heartbeat"


    @Volatile
    var foreground: Boolean = false
        private set

    private var channel: MethodChannel? = null


    private val mainHandler = Handler(Looper.getMainLooper())

    fun attach(context: Context, messenger: io.flutter.plugin.common.BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "setForeground" -> {
                    foreground = call.argument<Boolean>("value") ?: true
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
    }


    fun tick(context: Context) {
        if (foreground) return
        invoke(context, "tick")
    }


    fun notifyNetworkChanged(context: Context) {
        invoke(context, "networkChanged")
    }

    private fun invoke(context: Context, method: String) {
        mainHandler.post {
            val ch = channel ?: run {


                val engine = FlutterEngineCache.getInstance().get(PhoneAgentApplication.ENGINE_ID) ?: return@post
                MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            }
            ch.invokeMethod(method, null)
        }
    }
}
