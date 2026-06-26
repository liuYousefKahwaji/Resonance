package com.example.resonance

import android.content.Context
import android.os.Environment
import android.os.Handler
import android.os.Looper
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
    }

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
        // activeSink is accessed via a lambda in KotlinEventSink so the sink
        // captured at download() call time is always the most recently
        // registered one — avoids race if Dart subscribes after invokeMethod.
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

        // ── MethodChannel ─────────────────────────────────────────────────────
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

                    // ── download ──────────────────────────────────────────────
                    "download" -> {
                        val url       = call.argument<String>("url") ?: ""
                        val outputDir = call.argument<String>("outputDir")
                            ?: getExternalFilesDir(Environment.DIRECTORY_MUSIC)?.absolutePath
                            ?: filesDir.absolutePath

                        File(outputDir).mkdirs()

                        // Acknowledge immediately; progress comes via EventChannel.
                        result.success(null)

                        // Use a lambda provider so KotlinEventSink always
                        // references the CURRENT activeSink — even if Dart
                        // subscribes to the EventChannel slightly after this
                        // method call returns (common timing on first use).
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

                    else -> result.notImplemented()
                }
            }
    }
}

/**
 * Passed to Python as `event_sink`. Chaquopy transparently proxies method
 * calls on Kotlin objects from Python, so `event_sink.success(msg)` in
 * Python calls this Kotlin method directly.
 *
 * Uses a lambda provider instead of a direct reference so the current
 * activeSink is always resolved at the time of the call — this avoids the
 * race condition where the download coroutine starts before Dart's
 * receiveBroadcastStream() triggers onListen and sets activeSink.
 */
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
