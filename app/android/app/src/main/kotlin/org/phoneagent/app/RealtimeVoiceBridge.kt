package org.phoneagent.app

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.Collections
import java.util.Locale
import java.util.UUID


class RealtimeVoiceBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : RecognitionListener {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var recognizerComponent: ComponentName? = null
    private var listening = false
    private var pendingPermissionStart = false
    private var pendingSessionStart = false
    private var sessionActive = false
    private val audioManager = activity.getSystemService(AudioManager::class.java)
    private var previousAudioMode = AudioManager.MODE_NORMAL
    private var routedDeviceId: Int? = null
    private var headsetDuplexCapable = false
    private var tts: TextToSpeech? = null
    private val acknowledgementTone = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 45)
    private var ttsReady = false
    private var ttsEnginePackage: String? = null
    private val pendingTts = ArrayDeque<String>()
    private val activeTtsIds = Collections.synchronizedSet(mutableSetOf<String>())

    private data class AsrEngineStatus(
        val component: ComponentName?,
        val packageName: String?,
        val audioPermissionGranted: Boolean?,
    )

    init {
        val asrEngine = discoverAsrEngine()
        Log.i(
            TAG,
            "bridge init asrAvailable=${SpeechRecognizer.isRecognitionAvailable(activity)} " +
                "audioPermission=${hasAudioPermission()} engine=${asrEngine.packageName} " +
                "engineAudioPermission=${asrEngine.audioPermissionGranted}",
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> {
                    val currentAsr = discoverAsrEngine()
                    result.success(
                        mapOf(
                            "asr" to SpeechRecognizer.isRecognitionAvailable(activity),
                            "tts" to (ttsReady || tts != null),
                            "audioPermission" to hasAudioPermission(),
                            "asrEngine" to currentAsr.packageName,
                            "asrEngineAudioPermission" to currentAsr.audioPermissionGranted,
                            "sessionActive" to sessionActive,
                            "foregroundMicrophone" to RealtimeVoiceForegroundService.isRunning,
                            "routedDeviceId" to routedDeviceId,
                            "headsetDuplex" to headsetDuplexCapable,
                            "ttsVoice" to tts?.voice?.name,
                            "ttsPitch" to FALLBACK_TTS_PITCH,
                        )
                    )
                }
                "startSession" -> {
                    startVoiceSession()
                    result.success(true)
                }
                "ensureOutputRoute" -> {
                    if (sessionActive) applyPreferredCommunicationRoute()
                    result.success(
                        mapOf(
                            "routedDeviceId" to routedDeviceId,
                            "headsetDuplex" to headsetDuplexCapable,
                        )
                    )
                }
                "stopSession" -> {
                    stopVoiceSession()
                    result.success(true)
                }
                "startListening" -> {
                    startListening()
                    result.success(true)
                }
                "stopListening" -> {
                    listening = false
                    recognizer?.stopListening()
                    result.success(true)
                }
                "cancelListening" -> {
                    listening = false
                    recognizer?.cancel()
                    result.success(true)
                }
                "speak" -> {
                    val text = call.argument<String>("text")?.trim().orEmpty()
                    if (text.isNotEmpty()) enqueueSpeech(text)
                    result.success(text.isNotEmpty())
                }
                "stopSpeaking" -> {
                    pendingTts.clear()
                    activeTtsIds.clear()
                    tts?.stop()
                    emit("tts_stopped", extras = mapOf("remaining" to 0))
                    result.success(true)
                }
                "playAck" -> {


                    acknowledgementTone.startTone(ToneGenerator.TONE_PROP_ACK, 90)
                    result.success(true)
                }
                "isSpeaking" -> result.success(tts?.isSpeaking == true)
                else -> result.notImplemented()
            }
        }
        initTts()
    }

    private fun hasAudioPermission(): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun discoverAsrEngine(): AsrEngineStatus {
        val configured = Settings.Secure.getString(
            activity.contentResolver,
            "voice_recognition_service",
        )?.let(ComponentName::unflattenFromString)
        val discovered = activity.packageManager
            .queryIntentServices(
                Intent(RecognitionService.SERVICE_INTERFACE),
                PackageManager.MATCH_DEFAULT_ONLY,
            )
            .firstOrNull()
            ?.serviceInfo
            ?.let { ComponentName(it.packageName, it.name) }
        val component = configured ?: discovered
        val packageName = component?.packageName
        val enginePermission = packageName?.let {
            activity.packageManager.checkPermission(Manifest.permission.RECORD_AUDIO, it) ==
                PackageManager.PERMISSION_GRANTED
        }
        return AsrEngineStatus(component, packageName, enginePermission)
    }

    private fun startVoiceSession() {
        if (!hasAudioPermission()) {
            pendingSessionStart = true
            return
        }
        if (sessionActive) return
        try {

            RealtimeVoiceForegroundService.start(activity)
            configureVoiceAudioRoute()
            sessionActive = true
            pendingSessionStart = false
            emit(
                "session_start",
                extras = mapOf(
                    "foregroundMicrophone" to RealtimeVoiceForegroundService.isRunning,
                    "routedDeviceId" to routedDeviceId,
                    "headsetDuplex" to headsetDuplexCapable,
                ),
            )
        } catch (e: Exception) {
            sessionActive = false
            Log.e(TAG, "realtime voice session start failed", e)
            emit("error", message = "锁屏语音服务启动失败：${e.message ?: e.javaClass.simpleName}")
        }
    }

    private fun stopVoiceSession() {
        pendingSessionStart = false
        sessionActive = false
        releaseVoiceAudioRoute()
        RealtimeVoiceForegroundService.stop(activity)
        emit("session_stop")
    }

    private fun configureVoiceAudioRoute() {
        previousAudioMode = audioManager.mode
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        applyPreferredCommunicationRoute()
        tts?.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build(),
        )
    }

    private fun applyPreferredCommunicationRoute() {
        routedDeviceId = null
        headsetDuplexCapable = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = audioManager.availableCommunicationDevices
            val headsetTypes = listOf(
                AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            )
            val headset = headsetTypes.firstNotNullOfOrNull { type ->
                devices.firstOrNull { it.type == type }
            }


            val preferred = headset ?: devices.firstOrNull {
                it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            }
            if (preferred != null) {
                val applied = audioManager.setCommunicationDevice(preferred)
                if (applied) {
                    routedDeviceId = preferred.id
                    headsetDuplexCapable = preferred.type in setOf(
                        AudioDeviceInfo.TYPE_BLE_HEADSET,
                        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                        AudioDeviceInfo.TYPE_WIRED_HEADSET,
                        AudioDeviceInfo.TYPE_USB_HEADSET,
                    )
                }
                Log.i(
                    TAG,
                    "communication route applied=$applied type=${preferred.type} " +
                        "id=${preferred.id} name=${preferred.productName} " +
                        "fallbackSpeaker=${headset == null}",
                )
            } else {
                Log.w(TAG, "no headset or built-in speaker communication device available")
            }
        } else {
            @Suppress("DEPRECATION")
            audioManager.startBluetoothSco()
            @Suppress("DEPRECATION")
            audioManager.isBluetoothScoOn = true
            headsetDuplexCapable = true
            Log.i(TAG, "legacy Bluetooth SCO requested")
        }
    }

    private fun releaseVoiceAudioRoute() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                audioManager.stopBluetoothSco()
                @Suppress("DEPRECATION")
                audioManager.isBluetoothScoOn = false
            }
            audioManager.mode = previousAudioMode
        } catch (e: Exception) {
            Log.w(TAG, "release communication route failed", e)
        }
        routedDeviceId = null
        headsetDuplexCapable = false
    }

    private fun startListening() {
        val available = SpeechRecognizer.isRecognitionAvailable(activity)
        val asrEngine = discoverAsrEngine()
        Log.i(
            TAG,
            "startListening available=$available permission=${hasAudioPermission()} " +
                "engine=${asrEngine.packageName} " +
                "enginePermission=${asrEngine.audioPermissionGranted} listening=$listening",
        )
        if (!available) {
            Log.e(TAG, "recognition service unavailable to app")
            emit("error", message = "系统语音识别不可用")
            return
        }
        if (!hasAudioPermission()) {
            pendingPermissionStart = true
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                MainActivity.REQ_REALTIME_AUDIO,
            )
            return
        }
        if (asrEngine.audioPermissionGranted == false) {
            Log.e(TAG, "recognition engine lacks RECORD_AUDIO package=${asrEngine.packageName}")
            emit(
                "asr_error",
                message = "系统语音服务缺少麦克风权限",
                extras = mapOf(
                    "code" to SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS,
                    "terminal" to true,
                    "enginePackage" to asrEngine.packageName,
                ),
            )
            return
        }
        startVoiceSession()
        if (!sessionActive) return
        if (listening) return
        if (recognizer == null || recognizerComponent != asrEngine.component) {
            recognizer?.destroy()
            recognizerComponent = asrEngine.component
            recognizer = if (asrEngine.component != null) {
                SpeechRecognizer.createSpeechRecognizer(activity, asrEngine.component)
            } else {
                SpeechRecognizer.createSpeechRecognizer(activity)
            }.also {
                it.setRecognitionListener(this)
            }
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)


            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 450L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 2200L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1200L)
        }
        try {
            listening = true
            recognizer?.startListening(intent)
            Log.i(TAG, "recognizer start requested")
            emit("listen_start")
        } catch (e: Exception) {
            listening = false
            Log.e(TAG, "recognizer start failed", e)
            emit("error", message = e.message ?: "启动语音识别失败")
        }
    }

    fun onAudioPermissionResult(granted: Boolean) {
        emit("permission", extras = mapOf("granted" to granted))
        if (granted) {
            if (pendingSessionStart || pendingPermissionStart) startVoiceSession()
            if (pendingPermissionStart) {
                pendingPermissionStart = false
                startListening()
            }
        } else {
            pendingPermissionStart = false
            pendingSessionStart = false
        }
    }

    private fun initTts() {
        val serviceIntent = Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE)
        ttsEnginePackage = activity.packageManager
            .queryIntentServices(serviceIntent, PackageManager.MATCH_DEFAULT_ONLY)
            .firstOrNull()
            ?.serviceInfo
            ?.packageName
        Log.i(TAG, "tts engine discovered=$ttsEnginePackage")

        val onInit = TextToSpeech.OnInitListener { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            Log.i(TAG, "tts init status=$status ready=$ttsReady")
            if (ttsReady) {
                val languageStatus = tts?.setLanguage(Locale.SIMPLIFIED_CHINESE)
                Log.i(TAG, "tts language status=$languageStatus engine=${tts?.defaultEngine}")


                val chineseVoice = tts?.voices
                    ?.filter { it.locale.language == Locale.CHINESE.language }
                    ?.sortedWith(
                        compareBy<android.speech.tts.Voice> { it.isNetworkConnectionRequired }
                            .thenByDescending { it.quality }
                            .thenBy { it.latency }
                    )
                    ?.firstOrNull()
                if (chineseVoice != null) tts?.voice = chineseVoice
                tts?.setPitch(FALLBACK_TTS_PITCH)
                tts?.setSpeechRate(FALLBACK_TTS_RATE)
                Log.i(
                    TAG,
                    "tts voice=${tts?.voice?.name} locale=${tts?.voice?.locale} " +
                        "available=${tts?.voices?.size ?: 0} pitch=$FALLBACK_TTS_PITCH " +
                        "rate=$FALLBACK_TTS_RATE",
                )
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) =
                        emit("tts_start", extras = mapOf("remaining" to activeTtsIds.size))
                    override fun onDone(utteranceId: String?) = finishSpeech(utteranceId)
                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) = failSpeech(utteranceId, null)
                    override fun onError(utteranceId: String?, errorCode: Int) =
                        failSpeech(utteranceId, errorCode)
                })
                while (pendingTts.isNotEmpty()) speakNow(pendingTts.removeFirst())
                emit(
                    "tts_ready",
                    extras = mapOf(
                        "voice" to tts?.voice?.name,
                        "pitch" to FALLBACK_TTS_PITCH,
                        "rate" to FALLBACK_TTS_RATE,
                    ),
                )
            } else {
                Log.e(TAG, "tts initialization failed status=$status")
                emit("error", message = "系统语音合成初始化失败")
            }
        }
        tts = if (ttsEnginePackage != null) {


            TextToSpeech(activity, onInit, ttsEnginePackage)
        } else {
            TextToSpeech(activity, onInit)
        }
    }

    private fun enqueueSpeech(text: String) {
        if (!ttsReady) {
            pendingTts.addLast(text)
            return
        }
        speakNow(text)
    }

    private fun speakNow(text: String) {
        val utteranceId = UUID.randomUUID().toString()
        activeTtsIds.add(utteranceId)
        val status = tts?.speak(text, TextToSpeech.QUEUE_ADD, null, utteranceId)
            ?: TextToSpeech.ERROR
        if (status == TextToSpeech.ERROR) failSpeech(utteranceId, status)
    }

    private fun finishSpeech(utteranceId: String?) {
        if (utteranceId != null) activeTtsIds.remove(utteranceId)
        val remaining = activeTtsIds.size
        emit("tts_done", extras = mapOf("remaining" to remaining))
        if (remaining == 0) emit("tts_idle")
    }

    private fun failSpeech(utteranceId: String?, errorCode: Int?) {
        if (utteranceId != null) activeTtsIds.remove(utteranceId)
        val remaining = activeTtsIds.size
        emit(
            "tts_error",
            extras = mapOf("code" to errorCode, "remaining" to remaining),
        )
        if (remaining == 0) emit("tts_idle")
    }

    private fun bestText(results: Bundle?): String =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()

    private fun emit(
        kind: String,
        text: String? = null,
        message: String? = null,
        extras: Map<String, Any?> = emptyMap(),
    ) {
        val payload = mutableMapOf<String, Any?>("kind" to kind)
        if (text != null) payload["text"] = text
        if (message != null) payload["message"] = message
        payload.putAll(extras)
        mainHandler.post { channel.invokeMethod("event", payload) }
    }

    override fun onReadyForSpeech(params: Bundle?) = emit("ready")

    override fun onBeginningOfSpeech() {


        emit("speech_start")
    }

    override fun onRmsChanged(rmsdB: Float) = emit("level", extras = mapOf("value" to rmsdB))
    override fun onBufferReceived(buffer: ByteArray?) = Unit
    override fun onEndOfSpeech() = emit("speech_end")

    override fun onError(error: Int) {
        if (!listening) {
            Log.w(TAG, "recognizer duplicate/late error=$error ignored")
            return
        }
        listening = false
        Log.w(TAG, "recognizer error=$error")
        if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
            emit("listen_end", extras = mapOf("code" to error))
        } else if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
            emit(
                "asr_error",
                message = "系统语音服务缺少麦克风权限",
                extras = mapOf("code" to error, "terminal" to true),
            )
        } else {
            emit(
                "asr_error",
                message = "语音识别错误 $error",
                extras = mapOf("code" to error, "terminal" to false),
            )
        }
    }

    override fun onResults(results: Bundle?) {
        listening = false
        val text = bestText(results)
        Log.i(TAG, "recognizer final chars=${text.length}")
        emit("final", text = text)
    }

    override fun onPartialResults(partialResults: Bundle?) =
        emit("partial", text = bestText(partialResults))

    override fun onEvent(eventType: Int, params: Bundle?) = Unit

    fun dispose() {
        Log.i(TAG, "bridge dispose")
        pendingPermissionStart = false
        listening = false
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
        recognizerComponent = null
        pendingTts.clear()
        activeTtsIds.clear()
        tts?.stop()
        tts?.shutdown()
        tts = null
        ttsReady = false
        acknowledgementTone.release()
        stopVoiceSession()
    }

    companion object {
        private const val TAG = "RealtimeVoiceBridge"
        const val CHANNEL = "org.phoneagent.app/realtime_voice"
        private const val FALLBACK_TTS_PITCH = 1.0f
        private const val FALLBACK_TTS_RATE = 1.0f
    }
}
