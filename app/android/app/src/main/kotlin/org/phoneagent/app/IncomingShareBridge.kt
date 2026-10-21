package org.phoneagent.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.AtomicFile
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors


object IncomingShareBridge {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private val received = mutableSetOf<String>()
    private const val TAG = "IncomingShare"

    fun attach(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        channel = MethodChannel(messenger, "org.phoneagent.app/incoming_share").also { ch ->
            ch.setMethodCallHandler { call, result ->
                worker.execute {
                    try {
                        val answer: Any? = when (call.method) {
                            "publishTargets" -> {
                                val targets = call.argument<List<Map<String, String>>>("agents").orEmpty()
                                main.post {
                                    runCatching { PushNotifications.publishShareTargets(app, targets) }
                                        .onSuccess { result.success(null) }
                                        .onFailure { result.error("share_targets", it.message, null) }
                                }
                                return@execute
                            }
                            "pending" -> queue(app).listFiles().orEmpty()
                                .filter { it.extension == "json" }.sortedBy { it.lastModified() }
                                .map { jsonMap(JSONObject(it.readText())) }
                            "ack", "discard" -> {
                                val id = call.argument<String>("id") ?: error("Missing share id")
                                require(Regex("[a-f0-9-]{36}").matches(id))
                                val prefs = app.getSharedPreferences("incoming_share_receipts", Context.MODE_PRIVATE)
                                val ids = prefs.getStringSet("handled", emptySet()).orEmpty().toMutableSet()
                                ids.add(id)
                                check(prefs.edit().putStringSet("handled", ids.toList().takeLast(256).toSet()).commit())

                                if (call.method == "discard") File(inbox(app), id).deleteRecursively()
                                File(queue(app), "$id.json").delete()
                                null
                            }
                            else -> { main.post { result.notImplemented() }; return@execute }
                        }
                        main.post { result.success(answer) }
                    } catch (e: Exception) {
                        main.post { result.error("share_io", e.message, null) }
                    }
                }
            }
        }
    }


    fun receive(context: Context, intent: Intent?, restoredId: String?): String? {
        if (!accepts(intent)) return null
        val id = restoredId ?: UUID.randomUUID().toString()
        if (restoredId != null && context.getSharedPreferences("incoming_share_receipts", Context.MODE_PRIVATE)
                .getStringSet("handled", emptySet()).orEmpty().contains(id)) return id
        if (!received.add(id)) return id
        val app = context.applicationContext

        val snapshot = Intent(intent!!)
        worker.execute {
            if (File(queue(app), "$id.json").exists()) {
                notifyReady()
                return@execute
            }
            val files = JSONArray()
            val errors = JSONArray()
            val text = textOf(snapshot)
            try {
                for (uri in streamUris(snapshot)) {
                    try {
                        files.put(copyUri(app, uri, id, files.length(), snapshot.type))
                    } catch (e: Exception) {
                        errors.put("有一个文件无法读取，请从原应用重新分享（${e.javaClass.simpleName}）")
                    }
                }
                if (text.isBlank() && files.length() == 0 && errors.length() == 0) {
                    errors.put("来源应用没有提供可读取的文字或文件")
                }
                val envelope = JSONObject().put("id", id).put("text", text)
                    .put("files", files).put("errors", errors)
                    .put("targetAgentId", snapshot.getStringExtra(Intent.EXTRA_SHORTCUT_ID))
                val atomic = AtomicFile(File(queue(app), "$id.json"))
                val output = atomic.startWrite()
                try { output.write(envelope.toString().toByteArray()); atomic.finishWrite(output) }
                catch (e: Exception) { atomic.failWrite(output); throw e }
                Log.i(TAG, "ready id=$id files=${files.length()} errors=${errors.length()}")
                notifyReady()
            } catch (e: Exception) {
                Log.e(TAG, "import failed: ${e.javaClass.simpleName}")
                main.post { channel?.invokeMethod("importFailed", "分享保存失败，请检查手机剩余空间后重试") }
            }
        }
        return id
    }

    @Suppress("DEPRECATION")
    internal fun accepts(intent: Intent?): Boolean = when (intent?.action) {
        Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE, Intent.ACTION_PROCESS_TEXT -> true
        Intent.ACTION_VIEW -> intent.data?.scheme == "content"
        else -> false
    }

    internal fun textOf(intent: Intent): String = runCatching {
        val key = if (intent.action == Intent.ACTION_PROCESS_TEXT) Intent.EXTRA_PROCESS_TEXT else Intent.EXTRA_TEXT
        val body = intent.getCharSequenceExtra(key)?.toString()
            ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString().orEmpty()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT).orEmpty()
        listOf(subject.takeUnless { it.isBlank() || it == body }.orEmpty(), body)
            .filter { it.isNotBlank() }.joinToString("\n")
    }.getOrDefault("")

    @Suppress("DEPRECATION")
    internal fun streamUris(intent: Intent): List<Uri> {
        val uris = linkedSetOf<Uri>()

        intent.data?.takeIf { it.scheme == "content" }?.let { uris.add(it) }
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        }
        intent.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
        }
        return uris.toList()
    }

    private fun copyUri(context: Context, uri: Uri, id: String, index: Int, fallbackMime: String?): JSONObject {


        require(uri.scheme == "content") { "Only content URIs are supported" }
        val provider = context.packageManager.resolveContentProvider(uri.authority ?: "", 0)
        require(provider != null && provider.applicationInfo.uid != context.applicationInfo.uid)
        val resolver = context.contentResolver
        var name = "分享文件"
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
        }
        name = name.substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[\\p{Cntrl}]"), "_").take(160).ifBlank { "分享文件" }
        if (name == "." || name == "..") name = "分享文件"
        val directory = File(inbox(context), "$id/$index").apply { check(mkdirs() || isDirectory) }
        val target = File(directory, name)
        try {
            resolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(128 * 1024)
                    var count = input.read(buffer)
                    while (count != -1) {
                        check(directory.usableSpace > count + 32L * 1024 * 1024) { "Not enough free space" }
                        output.write(buffer, 0, count)
                        count = input.read(buffer)
                    }
                }
            } ?: error("Content provider returned no stream")
        } catch (e: Exception) { target.delete(); throw e }
        return JSONObject().put("name", name).put("path", target.absolutePath)
            .put("size", target.length()).put("mime", resolver.getType(uri) ?: fallbackMime ?: "application/octet-stream")
    }

    private fun queue(context: Context) = File(context.filesDir, "incoming_share_queue").apply { mkdirs() }
    private fun inbox(context: Context) = File(context.getExternalFilesDir(null)
        ?: error("Phone storage unavailable"), "shared_inbox").apply { mkdirs() }
    private fun notifyReady() { main.post { channel?.invokeMethod("available", null) } }
    private fun jsonMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith { key ->
        when (val v = value.get(key)) {
            is JSONObject -> jsonMap(v)
            is JSONArray -> (0 until v.length()).map { i -> (v.get(i) as? JSONObject)?.let(::jsonMap) ?: v.get(i) }
            JSONObject.NULL -> null
            else -> v
        }
    }
}
