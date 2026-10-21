package org.phoneagent.app

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel


object ReplyBridge {
    const val CHANNEL = "org.phoneagent.app/reply"

    private var channel: MethodChannel? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL)
    }

    fun send(agentId: String, text: String) {
        mainHandler.post {
            val ch = channel ?: run {
                val engine = FlutterEngineCache.getInstance().get(PhoneAgentApplication.ENGINE_ID) ?: return@post
                MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            }
            ch.invokeMethod("send", mapOf("agentId" to agentId, "text" to text))
        }
    }
}
