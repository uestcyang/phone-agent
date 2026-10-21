package org.phoneagent.app

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File


class DraftDictationBridge(private val activity: Activity, messenger: BinaryMessenger) {
    companion object { const val PERMISSION_REQUEST = 7193 }
    private val channel = MethodChannel(messenger, "org.phoneagent.app/draft_dictation")
    private var recorder: MediaRecorder? = null
    private var recordingFile: File? = null
    private var owner = ""
    private var generation = 0
    private var permissionReply: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            val requestedOwner = call.argument<String>("owner") ?: ""
            when (call.method) {
                "start" -> {
                    clear()
                    owner = requestedOwner
                    if (owner.isEmpty()) result.error("OWNER_REQUIRED", "缺少录音会话", null)
                    else if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        permissionReply = result
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
                    } else start(result)
                }
                "finish" -> {
                    if (requestedOwner != owner) result.success("")
                    else try { result.success(finish()) }
                    catch (_: Exception) { result.error("RECORD_FAILED", "录音无法读取，原文字未修改", null) }
                }
                "cancel" -> {
                    if (requestedOwner == owner) clear()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onPermissionResult(granted: Boolean) {
        val reply = permissionReply ?: return
        permissionReply = null
        if (granted) start(reply) else reply.error("MIC_PERMISSION", "麦克风权限未允许", null)
    }

    @Suppress("DEPRECATION")
    private fun start(reply: MethodChannel.Result) {
        val epoch = generation
        try {
            val folder = File(activity.filesDir, "draft_recordings").apply { mkdirs() }
            val file = File(folder, "draft-${System.currentTimeMillis()}-$epoch.m4a")
            recordingFile = file
            val mic = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(activity) else MediaRecorder()
            recorder = mic
            mic.setAudioSource(MediaRecorder.AudioSource.MIC)
            mic.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            mic.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            mic.setAudioChannels(1)
            mic.setAudioSamplingRate(16000)
            mic.setAudioEncodingBitRate(64000)
            mic.setMaxDuration(30 * 60 * 1000)
            mic.setOutputFile(file.absolutePath)
            mic.setOnInfoListener { _, what, _ ->
                if (epoch == generation && what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) {
                    val recipient = owner
                    val path = try { finish() } catch (_: Exception) { "" }
                    channel.invokeMethod("ended", mapOf("owner" to recipient, "audioPath" to path))
                }
            }
            mic.prepare()
            mic.start()
            reply.success(null)
        } catch (_: Exception) {
            clear()
            reply.error("RECORD_START_FAILED", "无法启动录音，请检查麦克风权限", null)
        }
    }

    private fun finish(): String {
        val file = recordingFile ?: return ""
        val mic = recorder ?: return ""
        try { mic.stop() } finally { mic.release(); recorder = null }


        recordingFile = null
        generation++
        return if (file.isFile && file.length() > 0) file.absolutePath else ""
    }

    private fun clear() {
        generation++
        try { recorder?.stop() } catch (_: Exception) {}
        try { recorder?.release() } catch (_: Exception) {}
        recorder = null
        recordingFile?.delete()
        recordingFile = null
        permissionReply?.error("CANCELLED", "录音已取消", null)
        permissionReply = null
        owner = ""
    }
    fun dispose() { clear(); channel.setMethodCallHandler(null) }
}
