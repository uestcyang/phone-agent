package org.phoneagent.app

import android.app.Activity
import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.widget.FrameLayout


class WidgetPreviewActivity : Activity() {
    private lateinit var host: AppWidgetHost
    private var widgetId: Int = -1

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = FrameLayout(this).apply { setBackgroundColor(Color.parseColor("#ECEFF1")) }
        setContentView(root)

        val mgr = AppWidgetManager.getInstance(this)


        AppWidgetHost(this, HOST_ID).deleteHost()
        host = AppWidgetHost(this, HOST_ID)
        host.startListening()

        widgetId = host.allocateAppWidgetId()
        val provider = ComponentName(this, PushWidgetProvider::class.java)
        val allowed = mgr.bindAppWidgetIdIfAllowed(widgetId, provider)
        Log.i(TAG, "bindAppWidgetIdIfAllowed widgetId=$widgetId allowed=$allowed")
        if (!allowed) {
            host.deleteAppWidgetId(widgetId)
            finish()
            return
        }

        val info = mgr.getAppWidgetInfo(widgetId)
        val hostView: AppWidgetHostView = host.createView(this, widgetId, info)
        hostView.setAppWidget(widgetId, info)
        root.addView(hostView)


        PushWidgetProvider.updateAllWidgets(applicationContext)
    }

    override fun onDestroy() {
        super.onDestroy()
        if (widgetId >= 0) {
            host.deleteAppWidgetId(widgetId)
        }
        host.stopListening()
    }

    companion object {
        private const val TAG = "WidgetPreview"
        private const val HOST_ID = 0x50524556
    }
}
