package org.phoneagent.app

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.Process
import android.util.Log
import kotlin.concurrent.thread


class DeviceBridgeProvider : ContentProvider() {
    private fun checkCaller() {
        require(Binder.getCallingUid() in listOf(0, 2000, Process.myUid())) { "shell only" }
    }
    override fun onCreate() = true
    override fun getType(uri: Uri) = "application/json"
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        checkCaller()
        require(uri.path == "/config" && mode == "w")
        val ctx = requireNotNull(context)
        val pipe = ParcelFileDescriptor.createPipe()
        thread(name = "owner-bridge-provision", isDaemon = true) {
            try {
                val text = ParcelFileDescriptor.AutoCloseInputStream(pipe[0]).use { stream ->
                    val bytes = stream.readNBytes(4097); require(bytes.size <= 4096); String(bytes, Charsets.UTF_8)
                }
                DeviceBridge.configure(ctx, text)
                Log.i("PhoneAgentDeviceBridge", "provisioned owner transport")
            } catch (_: Exception) { Log.w("PhoneAgentDeviceBridge", "provision rejected") }
        }
        return pipe[1]
    }
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        checkCaller()
        val ctx = requireNotNull(context)
        when (method) {
            "status" -> Unit
            "disable" -> DeviceBridge.stop(clear = true, context = ctx)
            "reconcile" -> DeviceBridge.reconcile(ctx)
            "restart_owned_child" -> DeviceBridge.restartOwnedChild()
            else -> throw IllegalArgumentException("unsupported method")
        }
        return Bundle().apply { putString("status", DeviceBridge.status(ctx).toString()) }
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
}
