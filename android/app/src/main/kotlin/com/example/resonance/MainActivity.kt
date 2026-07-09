package com.example.resonance

import android.content.Context
import android.media.audiofx.LoudnessEnhancer
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Process
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

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val METHOD_CHANNEL = "resonance/android_youtube"
        private const val EVENT_CHANNEL  = "resonance/android_youtube/events"
        private const val APP_CONTROL_CHANNEL = "resonance/app_control"
    }

    // ── Loudness enhancer instance ─────────────────────────────────────
    private var loudnessEnhancer: LoudnessEnhancer? = null

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

        // ── Loudness Enhancer channel ──────────────────────────────────────
        setupLoudnessChannel(flutterEngine)
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
