package org.phoneagent.app

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.util.Log


class MainProcessAnchorService : Service() {
    private val binder = Binder()

    override fun onCreate() {
        super.onCreate()


        Log.i("PhoneAgentAnchor", "main-process anchor created (pid=${android.os.Process.myPid()})")
    }

    override fun onBind(intent: Intent?): IBinder = binder
}
