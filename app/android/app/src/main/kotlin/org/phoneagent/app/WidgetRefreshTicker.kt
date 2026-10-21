package org.phoneagent.app

import android.app.Application
import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log


object WidgetRefreshTicker {

    private const val TAG = "WidgetRefreshTicker"
    const val ACTION_SET_PERIOD = "org.phoneagent.app.WIDGET_REFRESH_PERIOD"
    const val EXTRA_SECONDS = "seconds"


    private const val PREFS = "widget_snapshot_prefs"
    private const val KEY_PERIOD = "widget_refresh_period_sec"


    private const val DEFAULT_PERIOD_SEC = 90
    private const val MIN_PERIOD_SEC = 15

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    @Volatile private var running = false
    private var screenReceiver: BroadcastReceiver? = null


    private fun isKeepAliveProcess(ctx: Context): Boolean {
        val name = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) Application.getProcessName()
            else java.io.File("/proc/self/cmdline").readText().trim { it <= ' ' || it == ' ' }
        } catch (_: Exception) { null } ?: return true
        return name.endsWith(":keepalive")
    }

    @Synchronized
    fun start(ctx: Context) {
        val app = ctx.applicationContext
        if (running) return
        if (!isKeepAliveProcess(app)) {
            Log.i(TAG, "start skipped: not :keepalive process")
            return
        }
        if (widgetIds(app).isEmpty()) {
            Log.i(TAG, "start skipped: no widget instance on launcher")
            return
        }
        val t = HandlerThread("widget-refresh-ticker").also { it.start() }
        thread = t
        handler = Handler(t.looper)
        running = true
        registerScreenReceiver(app)
        Log.i(TAG, "start period=${periodOf(app)}s")
        scheduleNext(app, SystemClock.uptimeMillis())
    }

    @Synchronized
    fun stop(ctx: Context) {
        running = false
        handler?.removeCallbacksAndMessages(null)
        handler = null
        thread?.quitSafely()
        thread = null
        unregisterScreenReceiver(ctx.applicationContext)
        Log.i(TAG, "stop")
    }

    @Synchronized
    private fun pauseTicking() {
        handler?.removeCallbacksAndMessages(null)
    }


    @Synchronized
    private fun resumeTicking(ctx: Context) {
        if (!running) return
        val app = ctx.applicationContext
        handler?.removeCallbacksAndMessages(null)
        handler?.post {
            fire(app, "screen-on")
            scheduleNext(app, SystemClock.uptimeMillis())
        }
    }


    private fun scheduleNext(ctx: Context, targetAt: Long) {
        val h = handler ?: return
        if (!running) return
        val sec = periodOf(ctx)
        if (sec <= 0) {
            Log.i(TAG, "period<=0, periodic refresh disabled (回落纯事件驱动)")
            return
        }
        val interval = sec * 1000L
        val now = SystemClock.uptimeMillis()
        var next = targetAt + interval
        if (next < now) next = now + interval
        h.postAtTime({ tick(ctx, next) }, next)
    }

    private fun tick(ctx: Context, scheduledAt: Long) {
        if (!running) return
        val ids = widgetIds(ctx)
        if (ids.isEmpty()) {


            Log.i(TAG, "no widget instance, stopping ticker")
            stop(ctx)
            return
        }
        fire(ctx, "tick")
        scheduleNext(ctx, scheduledAt)
    }


    private fun fire(ctx: Context, why: String) {
        try {
            val i = Intent(PushWidgetProvider.ACTION_REFRESH).apply {
                component = ComponentName(ctx, PushWidgetProvider::class.java)
            }
            ctx.sendBroadcast(i)
            Log.i(TAG, "refresh broadcast sent ($why, period=${periodOf(ctx)}s)")
        } catch (e: Exception) {

            Log.w(TAG, "fire failed: ${e.message}")
        }
    }


    fun setPeriod(ctx: Context, sec: Int) {
        val v = if (sec <= 0) 0 else sec.coerceAtLeast(MIN_PERIOD_SEC)
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putInt(KEY_PERIOD, v).commit()
        Log.i(TAG, "setPeriod -> ${v}s")
        if (v > 0) {
            if (!running) start(ctx) else resumeTicking(ctx)
        } else {
            pauseTicking()
        }
    }

    private fun periodOf(ctx: Context): Int =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getInt(KEY_PERIOD, DEFAULT_PERIOD_SEC)

    private fun widgetIds(ctx: Context): IntArray = try {
        AppWidgetManager.getInstance(ctx)
            .getAppWidgetIds(ComponentName(ctx, PushWidgetProvider::class.java))
    } catch (_: Exception) { IntArray(0) }


    private fun registerScreenReceiver(ctx: Context) {
        if (screenReceiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                when (i?.action) {
                    Intent.ACTION_SCREEN_ON -> {
                        Log.i(TAG, "screen ON -> refresh now + resume")
                        resumeTicking(ctx)
                    }
                    Intent.ACTION_SCREEN_OFF -> {
                        Log.i(TAG, "screen OFF -> pause (省电硬约束,不是优化)")
                        pauseTicking()
                    }
                }
            }
        }
        val f = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        try {
            ctx.registerReceiver(r, f)
            screenReceiver = r
        } catch (e: Exception) {
            Log.w(TAG, "registerScreenReceiver failed: ${e.message}")
        }
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (pm != null && !pm.isInteractive) {
            Log.i(TAG, "screen already off at start -> stay paused")
            pauseTicking()
        }
    }

    private fun unregisterScreenReceiver(ctx: Context) {
        val r = screenReceiver ?: return
        try { ctx.unregisterReceiver(r) } catch (_: Exception) {}
        screenReceiver = null
    }
}


class WidgetRefreshPeriodReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        val ctx = context?.applicationContext ?: return
        if (intent?.action != WidgetRefreshTicker.ACTION_SET_PERIOD) return
        val sec = intent.getIntExtra(WidgetRefreshTicker.EXTRA_SECONDS, -1)
        if (sec < 0) return
        WidgetRefreshTicker.setPeriod(ctx, sec)
    }
}
