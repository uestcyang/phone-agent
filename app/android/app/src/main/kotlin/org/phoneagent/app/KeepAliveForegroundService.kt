package org.phoneagent.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat


class KeepAliveForegroundService : Service() {
    companion object {
        private const val TAG = "PhoneAgentKeepAlive"
        const val CHANNEL_ID = "phone_agent_keepalive"
        const val NOTIF_ID = 256
        const val ACTION_STOP = "org.phoneagent.app.action.STOP_KEEPALIVE"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        private const val PREFS = "keepalive_prefs"
        private const val KEY_TITLE = "last_title"
        private const val KEY_TEXT = "last_text"
        private const val KEY_USER_STOPPED = "user_stopped"

        @Volatile
        var isRunning = false
            private set

        fun start(context: Context, title: String, text: String) {
            savePrefs(context, title, text, userStopped = false)
            val intent = Intent(context, KeepAliveForegroundService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun ensureRunning(context: Context) {
            if (isRunning) return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (prefs.getBoolean(KEY_USER_STOPPED, false)) return
            val title = prefs.getString(KEY_TITLE, null) ?: "手机 Agent 在线"
            val text = prefs.getString(KEY_TEXT, null) ?: "正在恢复连接…"
            start(context, title, text)
        }

        fun update(context: Context, title: String, text: String) {
            if (!isRunning) {
                start(context, title, text)
                return
            }
            savePrefs(context, title, text, userStopped = false)
            val intent = Intent(context, KeepAliveForegroundService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.edit().putBoolean(KEY_USER_STOPPED, true).apply()
            val intent = Intent(context, KeepAliveForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        private fun savePrefs(context: Context, title: String, text: String, userStopped: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(KEY_TITLE, title)
                .putString(KEY_TEXT, text)
                .putBoolean(KEY_USER_STOPPED, userStopped)
                .apply()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null


    private val anchorConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            Log.i(TAG, "main-process anchor bound")
        }

        override fun onServiceDisconnected(name: ComponentName?) {


            Log.w(TAG, "main-process anchor disconnected; system will re-create via BIND_AUTO_CREATE")
        }
    }
    private var anchorBound = false

    override fun onCreate() {
        super.onCreate()
        createChannel()


        PushNotifications.createChannel(applicationContext)
        acquireWakeLock()
        bindMainProcessAnchor()
        KeepAliveWatchdog.schedule(applicationContext)
        HeartbeatAlarm.schedule(applicationContext)
    }

    private fun bindMainProcessAnchor() {
        if (anchorBound) return
        try {
            anchorBound = bindService(
                Intent(this, MainProcessAnchorService::class.java),
                anchorConnection,
                Context.BIND_AUTO_CREATE,
            )
            Log.i(TAG, "bindMainProcessAnchor requested=$anchorBound")
        } catch (e: Exception) {


            Log.w(TAG, "bindMainProcessAnchor failed", e)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            isRunning = false
            KeepAliveWatchdog.cancel(applicationContext)
            HeartbeatAlarm.cancel(applicationContext)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "手机 Agent 在线"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "正在连接…"
        val notification = buildNotification(title, text)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else {
            startForeground(NOTIF_ID, notification)
        }
        isRunning = true


        bindMainProcessAnchor()
        KeepAliveWatchdog.schedule(applicationContext)
        HeartbeatAlarm.schedule(applicationContext)


        try { WidgetRefreshTicker.start(applicationContext) } catch (_: Exception) {}
        DeviceBridge.reconcile(applicationContext)
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning = false
        DeviceBridge.stop()


        try { WidgetRefreshTicker.stop(applicationContext) } catch (_: Exception) {}
        releaseWakeLock()
        if (anchorBound) {
            try { unbindService(anchorConnection) } catch (_: Exception) {}
            anchorBound = false
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)


        ensureRunning(applicationContext)
        KeepAliveWatchdog.scheduleOneShotSoon(applicationContext)
    }


    override fun onTimeout(startId: Int, fgsType: Int) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf(startId)
        isRunning = false
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(CHANNEL_ID, "手机 Agent 保活", NotificationManager.IMPORTANCE_LOW).apply {
                description = "保持与服务端的长连接在后台不被系统冻结（不响铃不震动）"
                enableVibration(false)
                setSound(null, null)
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, flags)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(pendingIntent)
            .build()
    }

    @Suppress("DEPRECATION")
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "phoneagent:keepalive").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }
}
