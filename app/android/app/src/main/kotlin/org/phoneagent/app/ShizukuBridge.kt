package org.phoneagent.app

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.IBinder
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread


object ShizukuBridge {
    private const val REQUEST_CODE = 20260729

    private var appContext: Context? = null
    private var initialized = false


    private const val SERVICE_VERSION = 1

    @Volatile private var boundService: IShizukuUserService? = null
    private val pendingPermissionCallbacks = ConcurrentHashMap<Int, (Boolean) -> Unit>()


    private val bindLock = Object()
    @Volatile private var bindLatch: CountDownLatch? = null

    private val userServiceArgs by lazy {
        Shizuku.UserServiceArgs(ComponentName(appContext!!.packageName, ShizukuUserService::class.java.name))
            .daemon(false)
            .processNameSuffix("shizuku_user")
            .debuggable(BuildConfig.DEBUG)
            .version(SERVICE_VERSION)


            .tag("phoneagent_shizuku_user_v$SERVICE_VERSION")
    }

    private val userServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            boundService = if (binder != null && binder.pingBinder()) {
                IShizukuUserService.Stub.asInterface(binder)
            } else {
                null
            }
            bindLatch?.countDown()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            boundService = null
        }
    }

    private val binderReceivedListener = Shizuku.OnBinderReceivedListener {


    }

    private val binderDeadListener = Shizuku.OnBinderDeadListener {


        boundService = null
    }

    private val permissionResultListener = Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
        pendingPermissionCallbacks.remove(requestCode)?.invoke(grantResult == PackageManager.PERMISSION_GRANTED)
    }

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        appContext = context.applicationContext
        Shizuku.addBinderReceivedListenerSticky(binderReceivedListener)
        Shizuku.addBinderDeadListener(binderDeadListener)
        Shizuku.addRequestPermissionResultListener(permissionResultListener)
    }


    private fun binderAlive(): Boolean = try {
        Shizuku.pingBinder()
    } catch (_: Throwable) {
        false
    }

    fun handleMethodCall(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> {


                val alive = binderAlive()
                val granted = alive && try {
                    Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                } catch (_: Throwable) {
                    false
                }
                result.success(
                    mapOf(
                        "binderAlive" to alive,
                        "granted" to granted,


                        "uid" to if (alive) safeUid() else null,
                    )
                )
            }
            "requestPermission" -> {
                if (!binderAlive()) {
                    result.success(mapOf("granted" to false, "reason" to "binder_not_alive"))
                    return
                }
                try {
                    if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                        result.success(mapOf("granted" to true))
                        return
                    }
                } catch (e: Throwable) {
                    result.success(mapOf("granted" to false, "reason" to "check_failed: ${e.message}"))
                    return
                }
                pendingPermissionCallbacks[REQUEST_CODE] = { granted ->
                    result.success(mapOf("granted" to granted))
                }
                try {
                    Shizuku.requestPermission(REQUEST_CODE)
                } catch (e: Throwable) {
                    pendingPermissionCallbacks.remove(REQUEST_CODE)
                    result.success(mapOf("granted" to false, "reason" to "request_failed: ${e.message}"))
                }
            }
            "exec" -> {
                val cmd = call.argument<String>("cmd")
                if (cmd.isNullOrEmpty()) {
                    result.error("bad_args", "cmd required", null)
                    return
                }
                if (!binderAlive()) {
                    result.success(mapOf("ok" to false, "reason" to "binder_not_alive"))
                    return
                }
                val granted = try {
                    Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
                } catch (_: Throwable) {
                    false
                }
                if (!granted) {
                    result.success(mapOf("ok" to false, "reason" to "no_permission"))
                    return
                }


                thread(name = "shizuku-exec") {
                    val outcome = runCatching { execBlocking(cmd) }
                    val response = outcome.fold(
                        onSuccess = { (code, output) -> mapOf("ok" to true, "exitCode" to code, "output" to output) },
                        onFailure = { e -> mapOf("ok" to false, "reason" to "exec_failed: ${e.message}") },
                    )


                    android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(response) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun safeUid(): Int? = try {
        Shizuku.getUid()
    } catch (_: Throwable) {
        null
    }


    fun execForSelfTest(cmd: String): Pair<Int, String> = execBlocking(cmd)

    private fun execBlocking(cmd: String): Pair<Int, String> {
        val service = boundService ?: ensureBoundSync(timeoutMs = 8_000)
            ?: throw IllegalStateException("bind timeout")
        val raw = service.exec(cmd)
        val sepIdx = raw.indexOf(ShizukuUserService.SEP)
        if (sepIdx < 0) return Pair(-1, raw)
        val code = raw.substring(0, sepIdx).toIntOrNull() ?: -1
        val output = raw.substring(sepIdx + 1)
        return Pair(code, output)
    }


    private fun ensureBoundSync(timeoutMs: Long): IShizukuUserService? {
        boundService?.let { return it }
        val latch: CountDownLatch
        synchronized(bindLock) {
            boundService?.let { return it }
            val existing = bindLatch
            if (existing != null) {
                latch = existing
            } else {
                latch = CountDownLatch(1)
                bindLatch = latch
                try {
                    Shizuku.bindUserService(userServiceArgs, userServiceConnection)
                } catch (e: Throwable) {
                    bindLatch = null
                    return null
                }
            }
        }
        latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        synchronized(bindLock) { if (bindLatch === latch) bindLatch = null }
        return boundService
    }
}
