package com.example.resonance

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioRecord
import android.media.audiofx.LoudnessEnhancer
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.MediaStore
import androidx.annotation.Keep
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val METHOD_CHANNEL = "resonance/android_youtube"
        private const val EVENT_CHANNEL  = "resonance/android_youtube/events"
        private const val APP_CONTROL_CHANNEL = "resonance/app_control"
        private const val PLAYLIST_TRANSFER_CHANNEL = "resonance/playlist_transfer"
        private const val MUSIC_RECOGNITION_CHANNEL = "resonance/music_recognition"
        private const val QR_STORAGE_PERMISSION_REQUEST = 4102
        private const val MEDIA_PROJECTION_REQUEST = 4103
        private const val MAX_CAPTURE_DURATION_MS = 60_000
        private const val MAX_DEVICE_AUDIO_WAIT_MS = 20_000
    }

    // ── Loudness enhancer instance ─────────────────────────────────────
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var pendingQrFiles: List<Map<String, Any?>>? = null
    private var pendingQrResult: MethodChannel.Result? = null
    private var activeRecognitionRequest: RecognitionRequest? = null

    private data class RecognitionRequest(
        val id: String,
        val source: String,
        val captureDurationMs: Int,
        val waitTimeoutMs: Int,
        val result: MethodChannel.Result,
        val cancelled: AtomicBoolean = AtomicBoolean(false),
        @Volatile var audioRecord: AudioRecord? = null,
        @Volatile var projectionServiceStarted: Boolean = false,
    )

    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        AudioServicePlugin.getFlutterEngine(context)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(this))
        }

        val py     = Python.getInstance()
        val bridge = py.getModule("ytdlp_bridge")

        // ── EventChannel ─────────────────────────────────────────────────────
        var activeSink: EventChannel.EventSink? = null
        val pendingEvents = mutableListOf<String>()

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    activeSink = sink
                    pendingEvents.toList().forEach { sink.success(it) }
                    pendingEvents.clear()
                }
                override fun onCancel(arguments: Any?) {
                    activeSink = null
                }
            })

        // ── MethodChannel (YouTube operations) ─────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // ── search ────────────────────────────────────────────────
                    "search" -> {
                        val query = call.argument<String>("query") ?: ""
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val json = bridge.callAttr("search", query).toString()
                                withContext(Dispatchers.Main) { result.success(json) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("SEARCH_ERROR", e.message, null)
                                }
                            }
                        }
                    }

                    // ── getMetadata ──────────────────────────────────────────
                    "getMetadata" -> {
                        val url = call.argument<String>("url") ?: ""
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val json = bridge.callAttr("get_metadata", url).toString()
                                withContext(Dispatchers.Main) { result.success(json) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("METADATA_ERROR", e.message, null)
                                }
                            }
                        }
                    }

                    // ── getPlaylistMetadata ─────────────────────────────────
                    "getPlaylistMetadata" -> {
                        val url = call.argument<String>("url") ?: ""
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val json = bridge.callAttr("get_playlist_metadata", url).toString()
                                withContext(Dispatchers.Main) { result.success(json) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("PLAYLIST_METADATA_ERROR", e.message, null)
                                }
                            }
                        }
                    }

                    // ── getFirstThumbnail ───────────────────────────────────
                    "getFirstThumbnail" -> {
                        val query = call.argument<String>("query") ?: ""
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val json = bridge.callAttr("get_first_thumbnail", query).toString()
                                withContext(Dispatchers.Main) { result.success(json) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("THUMBNAIL_ERROR", e.message, null)
                                }
                            }
                        }
                    }

                    // ── download ──────────────────────────────────────────────
                    "download" -> {
                        val url = call.argument<String>("url") ?: ""
                        val outputDir = call.argument<String>("outputDir")
                            ?: getExternalFilesDir(Environment.DIRECTORY_MUSIC)?.absolutePath
                            ?: filesDir.absolutePath

                        File(outputDir).mkdirs()

                        // Acknowledge immediately; progress comes via EventChannel.
                        result.success(null)

                        val sinkProvider: () -> EventChannel.EventSink? = { activeSink }

                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                bridge.callAttr(
                                    "download",
                                    url,
                                    outputDir,
                                    KotlinEventSink(sinkProvider, pendingEvents),
                                )
                            } catch (e: Exception) {
                                Handler(Looper.getMainLooper()).post {
                                    val message = "error:${e.message}"
                                    val sink = activeSink
                                    if (sink != null) {
                                        sink.success(message)
                                    } else {
                                        pendingEvents.add(message)
                                    }
                                }
                            }
                        }
                    }

                    // ── getStreamUrl ──────────────────────────────────────────
                    "getStreamUrl" -> {
                        val url = call.argument<String>("url") ?: ""
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val streamUrl = bridge.callAttr("get_stream_url", url).toString()
                                withContext(Dispatchers.Main) { result.success(streamUrl) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("STREAM_ERROR", e.message, null)
                                }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_CONTROL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exitApp" -> {
                        result.success(null)
                        Handler(Looper.getMainLooper()).post {
                            try {
                                finishAndRemoveTask()
                            } catch (_: Exception) {
                                moveTaskToBack(true)
                            }
                            Handler(Looper.getMainLooper()).postDelayed({
                                Process.killProcess(Process.myPid())
                            }, 250)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLAYLIST_TRANSFER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveQrCodes" -> {
                        @Suppress("UNCHECKED_CAST")
                        val files = call.argument<List<Map<String, Any?>>>("files") ?: emptyList()
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
                        ) {
                            pendingQrFiles = files
                            pendingQrResult = result
                            requestPermissions(
                                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                                QR_STORAGE_PERMISSION_REQUEST,
                            )
                        } else {
                            saveQrCodesAsync(files, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        setupMusicRecognitionChannel(flutterEngine)

        // ── Loudness Enhancer channel ──────────────────────────────────────
        setupLoudnessChannel(flutterEngine)
    }

    private fun setupMusicRecognitionChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MUSIC_RECOGNITION_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "capturePcm" -> {
                    val source = call.argument<String>("source")
                    val captureDurationMs =
                        (call.argument<Any>("captureDurationMs") as? Number)?.toInt() ?: 8_000
                    val requestedWaitMs =
                        (call.argument<Any>("waitTimeoutMs") as? Number)?.toInt() ?: MAX_DEVICE_AUDIO_WAIT_MS

                    when {
                        source != "microphone" && source != "deviceOutput" -> {
                            result.error(
                                "INVALID_ARGUMENT",
                                "source must be 'microphone' or 'deviceOutput'",
                                null,
                            )
                        }
                        captureDurationMs <= 0 || captureDurationMs > MAX_CAPTURE_DURATION_MS -> {
                            result.error(
                                "INVALID_ARGUMENT",
                                "captureDurationMs must be between 1 and $MAX_CAPTURE_DURATION_MS",
                                null,
                            )
                        }
                        requestedWaitMs < 0 || (source == "deviceOutput" && requestedWaitMs == 0) -> {
                            result.error(
                                "INVALID_ARGUMENT",
                                "waitTimeoutMs must be positive for device-output capture",
                                null,
                            )
                        }
                        activeRecognitionRequest != null -> {
                            result.error("CAPTURE_BUSY", "Another music-recognition capture is active", null)
                        }
                        checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                            PackageManager.PERMISSION_GRANTED -> {
                            result.error(
                                "PERMISSION_DENIED",
                                "Microphone permission is required for music recognition",
                                null,
                            )
                        }
                        else -> {
                            val request = RecognitionRequest(
                                id = UUID.randomUUID().toString(),
                                source = checkNotNull(source),
                                captureDurationMs = captureDurationMs,
                                waitTimeoutMs = requestedWaitMs.coerceAtMost(MAX_DEVICE_AUDIO_WAIT_MS),
                                result = result,
                            )
                            activeRecognitionRequest = request
                            if (source == "microphone") {
                                captureMicrophone(request)
                            } else {
                                requestDeviceAudioConsent(request)
                            }
                        }
                    }
                }
                "cancelCapture" -> {
                    cancelActiveRecognition()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun captureMicrophone(request: RecognitionRequest) {
        Thread({
            try {
                if (request.cancelled.get()) {
                    throw PcmCaptureException(
                        PcmCaptureFailure("CAPTURE_CANCELLED", "Music recognition was cancelled"),
                    )
                }
                val record = PcmAudioCapture.createMicrophoneRecord()
                request.audioRecord = record
                val bytes = try {
                    PcmAudioCapture.capture(
                        audioRecord = record,
                        captureDurationMs = request.captureDurationMs,
                        waitTimeoutMs = null,
                        cancellation = {
                            if (request.cancelled.get()) {
                                PcmCaptureFailure("CAPTURE_CANCELLED", "Music recognition was cancelled")
                            } else {
                                null
                            }
                        },
                    )
                } finally {
                    request.audioRecord = null
                    record.release()
                }
                completeRecognition(request, bytes, null)
            } catch (error: PcmCaptureException) {
                completeRecognition(request, null, error.failure)
            } catch (error: Throwable) {
                completeRecognition(
                    request,
                    null,
                    PcmCaptureFailure(
                        "AUDIO_CAPTURE_FAILED",
                        error.message ?: "Microphone capture failed",
                    ),
                )
            }
        }, "ResonanceMicrophoneCapture").start()
    }

    private fun requestDeviceAudioConsent(request: RecognitionRequest) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            completeRecognition(
                request,
                null,
                PcmCaptureFailure(
                    "UNSUPPORTED",
                    "Device-audio capture requires Android 10 or newer",
                ),
            )
            return
        }
        launchDeviceAudioConsent(request)
    }

    private fun launchDeviceAudioConsent(request: RecognitionRequest) {
        try {
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            startActivityForResult(manager.createScreenCaptureIntent(), MEDIA_PROJECTION_REQUEST)
        } catch (error: Throwable) {
            completeRecognition(
                request,
                null,
                PcmCaptureFailure(
                    "MEDIA_PROJECTION_ERROR",
                    error.message ?: "Could not request device-audio sharing",
                ),
            )
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != MEDIA_PROJECTION_REQUEST) return

        val request = activeRecognitionRequest
        if (request == null || request.source != "deviceOutput" || request.cancelled.get()) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            completeRecognition(
                request,
                null,
                PcmCaptureFailure(
                    "PROJECTION_DENIED",
                    "Device-audio sharing was cancelled or denied",
                ),
            )
            return
        }

        request.projectionServiceStarted = true
        val started = MusicRecognitionCaptureService.startCapture(
            context = applicationContext,
            requestId = request.id,
            resultCode = resultCode,
            projectionData = data,
            captureDurationMs = request.captureDurationMs,
            waitTimeoutMs = request.waitTimeoutMs,
            callback = MusicRecognitionCaptureService.CaptureCallback { bytes, code, message ->
                completeRecognition(
                    request,
                    bytes,
                    if (code == null) null else PcmCaptureFailure(code, message ?: code),
                )
            },
        )
        if (!started) {
            request.projectionServiceStarted = false
            completeRecognition(
                request,
                null,
                PcmCaptureFailure("CAPTURE_BUSY", "Another device-audio capture is active"),
            )
            return
        }

        // The service was started while this activity was visible. Move Resonance
        // behind the user's audio app only after Android accepted the FGS launch.
        moveTaskToBack(true)
    }

    private fun cancelActiveRecognition() {
        val request = activeRecognitionRequest ?: return
        request.cancelled.set(true)
        when {
            request.source == "microphone" -> runCatching { request.audioRecord?.stop() }
            request.projectionServiceStarted ->
                MusicRecognitionCaptureService.cancelCapture(request.id)
            else -> completeRecognition(
                request,
                null,
                PcmCaptureFailure("CAPTURE_CANCELLED", "Music recognition was cancelled"),
            )
        }
    }

    private fun completeRecognition(
        request: RecognitionRequest,
        bytes: ByteArray?,
        failure: PcmCaptureFailure?,
    ) {
        runOnUiThread {
            if (activeRecognitionRequest?.id != request.id) return@runOnUiThread
            activeRecognitionRequest = null
            if (failure == null && bytes != null) {
                request.result.success(bytes)
            } else {
                val resolvedFailure = failure
                    ?: PcmCaptureFailure("AUDIO_CAPTURE_FAILED", "No PCM audio was returned")
                request.result.error(resolvedFailure.code, resolvedFailure.message, null)
            }
        }
    }

    private fun saveQrCodesAsync(files: List<Map<String, Any?>>, result: MethodChannel.Result) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                saveQrCodes(files)
                withContext(Dispatchers.Main) { result.success("Pictures/Resonance") }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("QR_SAVE_ERROR", e.message ?: "Could not save QR codes", null)
                }
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != QR_STORAGE_PERMISSION_REQUEST) return
        val files = pendingQrFiles
        val result = pendingQrResult
        pendingQrFiles = null
        pendingQrResult = null
        if (files == null || result == null) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            saveQrCodesAsync(files, result)
        } else {
            result.error("QR_SAVE_PERMISSION_DENIED", "Storage permission was denied", null)
        }
    }

    private fun saveQrCodes(files: List<Map<String, Any?>>) {
        if (files.isEmpty()) throw IllegalArgumentException("No QR images were provided")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        ) {
            throw SecurityException("Storage permission is required to save QR images on this Android version")
        }
        files.forEach { item ->
            val rawName = item["name"] as? String ?: throw IllegalArgumentException("A QR filename is missing")
            val name = File(rawName).name.let { if (it.endsWith(".png", true)) it else "$it.png" }
            val bytes = item["bytes"] as? ByteArray ?: throw IllegalArgumentException("QR image data is missing")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                    put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Resonance")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("Android could not create $name")
                try {
                    contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                        ?: throw IllegalStateException("Android could not open $name for writing")
                    values.clear()
                    values.put(MediaStore.Images.Media.IS_PENDING, 0)
                    contentResolver.update(uri, values, null, null)
                } catch (e: Exception) {
                    contentResolver.delete(uri, null, null)
                    throw e
                }
            } else {
                @Suppress("DEPRECATION")
                val directory = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                    "Resonance",
                )
                directory.mkdirs()
                FileOutputStream(File(directory, name)).use { it.write(bytes) }
            }
        }
    }

    /**
     * Registers a MethodChannel to control the LoudnessEnhancer audio effect.
     */
    private fun setupLoudnessChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "resonance/loudness_enhancer"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setGain" -> {
                    try {
                        val gainMB = call.argument<Int>("gainMB") ?: 0

                        if (gainMB <= 0) {
                            // Disable enhancer when at or below unity gain
                            loudnessEnhancer?.let {
                                it.enabled = false
                                it.release()
                            }
                            loudnessEnhancer = null
                            result.success(null)
                            return@setMethodCallHandler
                        }

                        // audio session ID 0 = attach to the global output mix.
                        // If you have access to your ExoPlayer instance here,
                        // prefer player.audioSessionId for tighter binding.
                        // Session 0 works reliably for our use case.
                        if (loudnessEnhancer == null) {
                            loudnessEnhancer = LoudnessEnhancer(0)
                        }

                        loudnessEnhancer!!.setTargetGain(gainMB)
                        loudnessEnhancer!!.enabled = true

                        result.success(null)
                    } catch (e: Exception) {
                        // LoudnessEnhancer is an optional effect — non-fatal.
                        result.error("LOUDNESS_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (isFinishing) cancelActiveRecognition()
        loudnessEnhancer?.release()
        loudnessEnhancer = null
        super.onDestroy()
    }
}

/**
 * Passed to Python as `event_sink`. Chaquopy transparently proxies method
 * calls on Kotlin objects from Python, so `event_sink.success(msg)` in
 * Python calls this Kotlin method directly.
 */
// Called reflectively from Python. Without @Keep, R8 renames this class and
// its success method in release builds, leaving Python with an obfuscated
// object (for example "b") which has no attribute named "success".
@Keep
class KotlinEventSink(
    private val sinkProvider: () -> EventChannel.EventSink?,
    private val pendingEvents: MutableList<String>,
) {
    fun success(message: String) {
        Handler(Looper.getMainLooper()).post {
            val sink = sinkProvider()
            if (sink != null) {
                sink.success(message)
            } else {
                pendingEvents.add(message)
            }
        }
    }
}
