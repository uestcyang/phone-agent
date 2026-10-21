package org.phoneagent.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel


class MainActivity : FlutterActivity() {
    private val dlChannel = "org.phoneagent.app/downloader"
    private val routingChannel = "org.phoneagent.app/routing"
    private val permissionChannel = "org.phoneagent.app/permissions"
    private var routingMethodChannel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var realtimeVoiceBridge: RealtimeVoiceBridge? = null
    private var draftDictationBridge: DraftDictationBridge? = null
    private var incomingShareId: String? = null

    companion object {
        private const val REQ_NOTIFICATION_PERMISSION = 7001
        const val REQ_REALTIME_AUDIO = 7002
    }


    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        val cache = FlutterEngineCache.getInstance()
        val cached = cache.get(PhoneAgentApplication.ENGINE_ID)
        if (cached != null && cached.dartExecutor.isExecutingDart) {
            return cached
        }
        if (cached != null) {
            cache.remove(PhoneAgentApplication.ENGINE_ID)
        }
        return PhoneAgentApplication.bootstrapEngine(context.applicationContext)
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false


    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        incomingShareId = IncomingShareBridge.receive(this, intent, savedInstanceState?.getString("incomingShareId"))
    }

    override fun onSaveInstanceState(outState: Bundle) {
        incomingShareId?.let { outState.putString("incomingShareId", it) }
        super.onSaveInstanceState(outState)
    }


    private fun extractRouteExtras(intent: Intent?): Map<String, String>? {
        val agentId = intent?.getStringExtra("open_agent_id")
        val tab = intent?.getStringExtra("open_tab")
        if (agentId.isNullOrEmpty() && tab.isNullOrEmpty()) return null
        val result = mutableMapOf<String, String>()
        if (!agentId.isNullOrEmpty()) result["agent_id"] = agentId
        if (!tab.isNullOrEmpty()) result["tab"] = tab
        return result
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incomingShareId = IncomingShareBridge.receive(this, intent, null)


        val extras = extractRouteExtras(intent)
        if (extras != null) {
            routingMethodChannel?.invokeMethod("routePush", extras)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        realtimeVoiceBridge?.dispose()
        realtimeVoiceBridge = RealtimeVoiceBridge(this, messenger)
        draftDictationBridge?.dispose()
        draftDictationBridge = DraftDictationBridge(this, messenger)

        MethodChannel(messenger, dlChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "download" -> {
                    val url = call.argument<String>("url")
                    val filename = call.argument<String>("filename")


                    val token = call.argument<String>("token")
                    if (url == null || filename == null) {
                        result.error("bad_args", "url/filename required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as android.app.DownloadManager
                        val request = android.app.DownloadManager.Request(android.net.Uri.parse(url))
                            .setTitle(filename)
                            .setNotificationVisibility(android.app.DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                            .setDestinationInExternalPublicDir(android.os.Environment.DIRECTORY_DOWNLOADS, filename)
                            .setAllowedOverMetered(true)
                            .setAllowedOverRoaming(true)
                        if (!token.isNullOrEmpty()) {
                            request.addRequestHeader("Authorization", "Bearer $token")
                        }
                        result.success(dm.enqueue(request))
                    } catch (e: Exception) {
                        result.error("download_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }


        val routing = MethodChannel(messenger, routingChannel)
        routingMethodChannel = routing
        routing.setMethodCallHandler { call, result ->
            when (call.method) {

                "consumeInitialRoute" -> result.success(extractRouteExtras(intent))
                else -> result.notImplemented()
            }
        }


        MethodChannel(messenger, permissionChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    val granted = ContextCompat.checkSelfPermission(
                        this, Manifest.permission.POST_NOTIFICATIONS
                    ) == PackageManager.PERMISSION_GRANTED
                    if (granted) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    pendingPermissionResult = result
                    ActivityCompat.requestPermissions(
                        this,
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        REQ_NOTIFICATION_PERMISSION
                    )
                }


                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }


                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("battery_opt_failed", e.message, null)
                    }
                }


                "hasManageExternalStorage" -> {
                    val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
                        Environment.isExternalStorageManager()
                    result.success(granted)
                }


                "requestManageExternalStorage" -> {
                    try {
                        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("manage_storage_failed", e.message, null)
                    }
                }


                "openFolder" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    result.success(openFolderNative(path))
                }
                else -> result.notImplemented()
            }
        }
    }


    private fun openFolderNative(path: String): Boolean {
        val uri = Uri.parse("file://$path")

        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "resource/folder")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {
        }

        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "vnd.android.document/directory")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {
        }

        try {
            val intent = packageManager.getLaunchIntentForPackage("com.android.fileexplorer")
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {
        }

        return false
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == DraftDictationBridge.PERMISSION_REQUEST) {
            draftDictationBridge?.onPermissionResult(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        } else if (requestCode == REQ_NOTIFICATION_PERMISSION) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        } else if (requestCode == REQ_REALTIME_AUDIO) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            realtimeVoiceBridge?.onAudioPermissionResult(granted)
        }
    }

    override fun onDestroy() {
        draftDictationBridge?.dispose()
        draftDictationBridge = null
        realtimeVoiceBridge?.dispose()
        realtimeVoiceBridge = null
        super.onDestroy()
    }
}
