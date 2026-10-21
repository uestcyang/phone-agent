package org.phoneagent.app

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import androidx.core.app.NotificationManagerCompat


class PhoneAgentApplication : Application() {


    private fun currentProcessName(): String = try {
        java.io.File("/proc/self/cmdline").readText().substringBefore('\u0000')
    } catch (e: Exception) {
        packageName
    }

    override fun onCreate() {
        super.onCreate()

        if (currentProcessName().endsWith(":keepalive")) {
            return
        }

        bootstrapEngine(applicationContext)
    }

    companion object {
        const val ENGINE_ID = "phone_agent_main_engine"
        private const val KEEPALIVE_CHANNEL = "org.phoneagent.app/keepalive"
        private const val PUSH_CHANNEL = "org.phoneagent.app/push"
        private const val WIDGET_CHANNEL = "org.phoneagent.app/widget"
        private const val WIDGET_TOKEN_CHANNEL = "org.phoneagent.app/widget_token"


        private const val SHIZUKU_CHANNEL = "org.phoneagent.app/shizuku"


        fun bootstrapEngine(appContext: Context): FlutterEngine {


            PushNotifications.createChannel(appContext)

            val engine = FlutterEngine(appContext)
            GeneratedPluginRegistrant.registerWith(engine)
            IncomingShareBridge.attach(appContext, engine.dartExecutor.binaryMessenger)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)

            val messenger = engine.dartExecutor.binaryMessenger

            HeartbeatBridge.attach(appContext, messenger)
            ReplyBridge.attach(messenger)
            NetworkWatcher.register(appContext)


            ShizukuBridge.init(appContext)


                MethodChannel(messenger, KEEPALIVE_CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title") ?: "手机 Agent 在线"
                        val text = call.argument<String>("text") ?: "正在连接…"
                        KeepAliveForegroundService.start(appContext, title, text)
                        result.success(null)
                    }
                    "update" -> {
                        val title = call.argument<String>("title") ?: "手机 Agent 在线"
                        val text = call.argument<String>("text") ?: ""
                        KeepAliveForegroundService.update(appContext, title, text)
                        result.success(null)
                    }
                    "stop" -> {
                        KeepAliveForegroundService.stop(appContext)
                        result.success(null)
                    }
                    "checkNotificationPermission" -> {
                        result.success(NotificationManagerCompat.from(appContext).areNotificationsEnabled())
                    }
                    else -> result.notImplemented()
                }
            }

            MethodChannel(messenger, PUSH_CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "post" -> {
                        val title = call.argument<String>("title") ?: ""
                        val body = call.argument<String>("body") ?: ""
                        val agentId = call.argument<String>("agentId") ?: ""
                        val agentDisplayName = call.argument<String>("agentDisplayName") ?: agentId


                        val silent = call.argument<Boolean>("silent") ?: false
                        if (agentId.isNotEmpty()) {


                            val text = if (title.isNotBlank() && title != agentDisplayName) "$title\n$body" else body
                            PushNotifications.post(appContext, agentId, agentDisplayName, text, silent = silent)
                        }
                        result.success(null)
                    }


                    "getSystemInterruptionFilter" -> {
                        val nm = appContext.getSystemService(NotificationManager::class.java)
                        result.success(nm.currentInterruptionFilter)
                    }


                    "isPackageInstalled" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        val ok = pkg.isNotEmpty() &&
                            appContext.packageManager.getLaunchIntentForPackage(pkg) != null
                        result.success(ok)
                    }


                    "openExternalApp" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        val launch = if (pkg.isEmpty()) null
                        else appContext.packageManager.getLaunchIntentForPackage(pkg)
                        if (launch == null) {
                            result.success(false)
                        } else {
                            try {
                                launch.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                                appContext.startActivity(launch)
                                result.success(true)
                            } catch (_: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }


            MethodChannel(messenger, WIDGET_CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "updatePushWidget" -> {
                        try {
                            val kind = call.argument<String>("kind") ?: "quota"
                            val title = call.argument<String>("title") ?: ""
                            val body = call.argument<String>("body") ?: ""
                            val level = call.argument<String>("level") ?: ""
                            val badge = call.argument<String>("badge") ?: ""
                            val tsEpoch = call.argument<Number>("ts_epoch")?.toLong() ?: 0L
                            val remainPct = call.argument<Number>("remain_pct")?.toDouble() ?: -1.0
                            val elapsedMin = call.argument<Number>("elapsed_min")?.toDouble() ?: 0.0
                            val refreshH = call.argument<Number>("refresh_h")?.toDouble() ?: -1.0
                            val fetchAt = call.argument<Number>("fetch_at_epoch")?.toLong() ?: 0L
                            val refreshAt = call.argument<Number>("refresh_at_epoch")?.toLong() ?: 0L
                            val lost = call.argument<Boolean>("lost") ?: false

                            appContext.getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE).edit()
                                .putString("flutter.latest_push_kind", kind)
                                .putString("flutter.latest_push_title", title)
                                .putString("flutter.latest_push_body", body)
                                .putString("flutter.latest_push_level", level)
                                .putString("flutter.latest_push_badge", badge)
                                .putLong("flutter.latest_push_ts_epoch", tsEpoch)
                                .putLong("flutter.latest_push_remain_pct", java.lang.Double.doubleToRawLongBits(remainPct))
                                .putLong("flutter.latest_push_elapsed_min", java.lang.Double.doubleToRawLongBits(elapsedMin))
                                .putLong("flutter.latest_push_refresh_h", java.lang.Double.doubleToRawLongBits(refreshH))
                                .putLong("flutter.latest_push_fetch_at_epoch", fetchAt)
                                .putLong("flutter.latest_push_refresh_at_epoch", refreshAt)
                                .putBoolean("flutter.latest_push_lost", lost)
                                .commit()

                            PushWidgetProvider.updateAllWidgets(appContext)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("widget_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }


            MethodChannel(messenger, WIDGET_TOKEN_CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "publish" -> {
                        val token = call.argument<String>("token") ?: ""
                        val bundle = android.os.Bundle().apply {
                            putString(WidgetTokenProvider.EXTRA_TOKEN, token)
                            putString("summary_url", call.argument<String>("summary_url"))
                            putString("wallet_token", call.argument<String>("wallet_token"))
                            putString("ack_url", call.argument<String>("ack_url"))
                        }
                        try {
                            appContext.contentResolver.call(
                                WidgetTokenProvider.CONTENT_URI,
                                WidgetTokenProvider.METHOD_SET_TOKEN,
                                token,
                                bundle,
                            )
                        } catch (e: Exception) {


                            android.util.Log.w("PhoneAgentApp", "widget_token publish 跨进程调用失败: ${e.message}")
                        }


                        appContext.sendBroadcast(
                            android.content.Intent(appContext, PushWidgetProvider::class.java).apply {
                                action = "org.phoneagent.app.REFRESH_WIDGET"
                            }
                        )
                        result.success(null)
                    }


                    "refresh" -> {
                        appContext.sendBroadcast(
                            android.content.Intent(appContext, PushWidgetProvider::class.java).apply {
                                action = "org.phoneagent.app.REFRESH_WIDGET"
                            }
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

            MethodChannel(messenger, SHIZUKU_CHANNEL).setMethodCallHandler { call, result ->
                ShizukuBridge.handleMethodCall(call, result)
            }

            return engine
        }
    }
}
