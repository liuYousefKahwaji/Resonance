package com.example.resonance

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.audiofx.LoudnessEnhancer
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.MediaStore
import androidx.annotation.Keep
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import com.ryanheise.audioservice.AudioServiceFragmentActivity
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

class MainActivity : AudioServiceFragmentActivity() {

    companion object {
        private const val METHOD_CHANNEL = "resonance/android_youtube"
        private const val EVENT_CHANNEL  = "resonance/android_youtube/events"
        private const val APP_CONTROL_CHANNEL = "resonance/app_control"
        private const val PLAYLIST_TRANSFER_CHANNEL = "resonance/playlist_transfer"
        private const val MUSIC_RECOGNITION_CHANNEL = "resonance/music_recognition"
        private const val ANDROID_ENTRYPOINT_CHANNEL = "resonance/android_entrypoints"
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
    private var androidEntrypointChannel: MethodChannel? = null
    private var activityResumed = false
    private var entrypointDispatchScheduled = false
    private var minimizedTileLaunch = false

    private data class RecognitionRequest(
        val id: String,
        val source: String,
        val captureDurationMs: Int,
        val waitTimeoutMs: Int,
        val result: MethodChannel.Result,
        val cancelled: AtomicBoolean = AtomicBoolean(false),
        @Volatile var captureServiceStarted: Boolean = false,
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        minimizedTileLaunch = shouldMinimizeTileLaunch(intent)
        if (minimizedTileLaunch) setTheme(R.style.TileLaunchTheme)
        super.onCreate(savedInstanceState)
        if (minimizedTileLaunch) applyMinimizedTileWindow()
        handleLaunchIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (shouldMinimizeTileLaunch(intent) && !activityResumed) {
            minimizedTileLaunch = true
            applyMinimizedTileWindow()
        } else if (!shouldMinimizeTileLaunch(intent)) {
            restoreNormalWindow()
        }
        setIntent(intent)
        handleLaunchIntent(intent)
    }

    override fun onPostResume() {
        super.onPostResume()
        activityResumed = true
        MusicRecognitionCoordinator.setActivityVisible(true)
        if (minimizedTileLaunch && !MusicRecognitionCoordinator.tileSnapshot(this).active) {
            restoreNormalWindow()
        }
        scheduleEntrypointDispatch()
    }

    override fun onPause() {
        activityResumed = false
        MusicRecognitionCoordinator.setActivityVisible(false)
        super.onPause()
    }

    override fun onStop() {
        MusicRecognitionCoordinator.setActivityVisible(false)
        super.onStop()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AndroidBassBoostBridge.register(flutterEngine)

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
                        val limit = (call.argument<Int>("limit") ?: 10).coerceIn(1, 10)
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val json = bridge.callAttr("search", query, limit).toString()
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
        setupAndroidEntrypointChannel(flutterEngine)

        // ── Loudness Enhancer channel ──────────────────────────────────────
        setupLoudnessChannel(flutterEngine)
    }

    private fun setupAndroidEntrypointChannel(flutterEngine: FlutterEngine) {
        androidEntrypointChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ANDROID_ENTRYPOINT_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPendingAction" -> result.success(
                        MusicRecognitionCoordinator.pendingLaunchAction(this)
                            ?: MusicRecognitionCoordinator.pendingResultAction(this),
                    )
                    "acknowledgeAction" -> {
                        MusicRecognitionCoordinator.acknowledgeLaunchAction(
                            this,
                            call.argument<String>("id"),
                        )
                        result.success(null)
                        scheduleEntrypointDispatch()
                    }
                    "getDefaultRecognitionSource" ->
                        result.success(MusicRecognitionCoordinator.getDefaultSource(this))
                    "setDefaultRecognitionSource" -> {
                        val source = call.argument<String>("source")
                        if (source != "microphone" && source != "deviceOutput") {
                            result.error("INVALID_SOURCE", "Unknown recognition source", null)
                        } else {
                            MusicRecognitionCoordinator.setDefaultSource(this, source)
                            result.success(null)
                        }
                    }
                    "beginRecognition" -> {
                        val fromTile = call.argument<Boolean>("fromTile") == true
                        val acquired = MusicRecognitionCoordinator.beginScan(this, fromTile)
                        runCatching { result.success(acquired) }.onFailure {
                            if (acquired) MusicRecognitionCoordinator.resetScan(this)
                        }
                    }
                    "updateRecognitionStage" -> {
                        MusicRecognitionCoordinator.updateStage(
                            this,
                            call.argument<String>("stage") ?: "listening",
                        )
                        result.success(null)
                    }
                    "finishRecognition" -> {
                        @Suppress("UNCHECKED_CAST")
                        val outcome = (call.arguments as? Map<String, Any?>)?.toMap()
                            ?: mapOf(
                                "success" to false,
                                "message" to "Music recognition ended unexpectedly.",
                            )
                        result.success(MusicRecognitionCoordinator.finishScan(this, outcome))
                    }
                    "resetRecognition" -> {
                        MusicRecognitionCoordinator.resetScan(this)
                        result.success(null)
                    }
                    "clearPendingRecognitionResult" -> {
                        MusicRecognitionCoordinator.clearPendingResult(
                            this,
                            call.argument<String>("id"),
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        scheduleEntrypointDispatch()
    }

    private fun handleLaunchIntent(sourceIntent: Intent?) {
        val launchAction: Map<String, Any?>? = when (sourceIntent?.action) {
            Intent.ACTION_SEND -> {
                val text = runCatching {
                    sourceIntent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                        ?: sourceIntent.clipData
                            ?.takeIf { it.itemCount > 0 }
                            ?.getItemAt(0)
                            ?.coerceToText(this)
                            ?.toString()
                }.getOrNull()
                text?.trim()?.takeIf { it.isNotEmpty() }?.let {
                    mapOf("kind" to "share", "text" to it)
                }
            }
            MusicRecognitionCoordinator.ACTION_START_RECOGNITION -> mapOf(
                "kind" to "startRecognition",
                "source" to (
                    sourceIntent.getStringExtra(MusicRecognitionCoordinator.EXTRA_SOURCE)
                        ?: MusicRecognitionCoordinator.getDefaultSource(this)
                    ),
                "fromTile" to sourceIntent.getBooleanExtra(
                    MusicRecognitionCoordinator.EXTRA_FROM_TILE,
                    false,
                ),
            )
            MusicRecognitionCoordinator.ACTION_OPEN_RECOGNITION_PICKER ->
                mapOf("kind" to "openRecognitionPicker")
            MusicRecognitionCoordinator.ACTION_OPEN_RECOGNITION_RESULT -> {
                val pending = MusicRecognitionCoordinator.pendingResultAction(this)
                val requestedId = sourceIntent.getStringExtra(
                    MusicRecognitionCoordinator.EXTRA_RESULT_ID,
                )
                pending?.takeIf { requestedId == null || it["id"] == requestedId }
            }
            else -> null
        }
        sourceIntent?.action = null
        if (launchAction == null) return
        MusicRecognitionCoordinator.enqueueLaunchAction(this, launchAction)
        scheduleEntrypointDispatch()
    }

    private fun scheduleEntrypointDispatch() {
        if (!activityResumed || androidEntrypointChannel == null || entrypointDispatchScheduled) return
        entrypointDispatchScheduled = true
        Handler(Looper.getMainLooper()).post {
            entrypointDispatchScheduled = false
            if (!activityResumed) return@post
            val pending = MusicRecognitionCoordinator.pendingLaunchAction(this)
                ?: MusicRecognitionCoordinator.pendingResultAction(this)
                ?: return@post
            androidEntrypointChannel?.invokeMethod("onLaunchAction", pending)
        }
    }

    private fun shouldMinimizeTileLaunch(sourceIntent: Intent?): Boolean =
        sourceIntent?.action == MusicRecognitionCoordinator.ACTION_START_RECOGNITION &&
            sourceIntent.getBooleanExtra(MusicRecognitionCoordinator.EXTRA_FROM_TILE, false) &&
            sourceIntent.getBooleanExtra(
                MusicRecognitionCoordinator.EXTRA_MINIMIZED_TILE_LAUNCH,
                false,
            ) &&
            sourceIntent.getStringExtra(MusicRecognitionCoordinator.EXTRA_SOURCE) == "microphone" &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun applyMinimizedTileWindow() {
        window.attributes = window.attributes.apply { alpha = 0.01f }
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    private fun restoreNormalWindow() {
        if (!minimizedTileLaunch) return
        minimizedTileLaunch = false
        window.attributes = window.attributes.apply { alpha = 1f }
        setTheme(R.style.NormalTheme)
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
        request.captureServiceStarted = true
        val started = MusicRecognitionCaptureService.startMicrophoneCapture(
            context = applicationContext,
            requestId = request.id,
            captureDurationMs = request.captureDurationMs,
            callback = MusicRecognitionCaptureService.CaptureCallback { bytes, code, message ->
                completeRecognition(
                    request,
                    bytes,
                    if (code == null) null else PcmCaptureFailure(code, message ?: code),
                )
            },
        )
        if (!started) {
            request.captureServiceStarted = false
            completeRecognition(
                request,
                null,
                PcmCaptureFailure("CAPTURE_BUSY", "Another music-recognition capture is active"),
            )
            return
        }
        if (MusicRecognitionCoordinator.isTileScanActive(this)) {
            moveTaskToBack(true)
        }
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

        request.captureServiceStarted = true
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
            request.captureServiceStarted = false
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
            request.captureServiceStarted -> {
                MusicRecognitionCaptureService.cancelCapture(request.id)
                Handler(Looper.getMainLooper()).postDelayed({
                    if (activeRecognitionRequest?.id == request.id && request.cancelled.get()) {
                        completeRecognition(
                            request,
                            null,
                            PcmCaptureFailure("CAPTURE_CANCELLED", "Music recognition was cancelled"),
                        )
                    }
                }, 1_500)
            }
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
            MusicRecognitionCaptureService.releaseReservation(request.id)
            if (activeRecognitionRequest?.id != request.id) return@runOnUiThread
            activeRecognitionRequest = null
            val delivered = if (failure == null && bytes != null) {
                runCatching { request.result.success(bytes) }
            } else {
                val resolvedFailure = failure
                    ?: PcmCaptureFailure("AUDIO_CAPTURE_FAILED", "No PCM audio was returned")
                runCatching {
                    request.result.error(resolvedFailure.code, resolvedFailure.message, null)
                }
            }
            if (delivered.isFailure) MusicRecognitionCoordinator.resetScan(this)
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
        activityResumed = false
        MusicRecognitionCoordinator.setActivityVisible(false)
        if (isFinishing) {
            cancelActiveRecognition()
            MusicRecognitionCoordinator.resetScan(this)
        }
        loudnessEnhancer?.release()
        loudnessEnhancer = null
        androidEntrypointChannel = null
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
