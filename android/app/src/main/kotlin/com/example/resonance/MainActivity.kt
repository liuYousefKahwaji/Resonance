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
        var activeSink: EventChannel.EventSink? = null

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    activeSink = sink
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
                                val pyResults = bridge.callAttr("search", query)
                                val builtins = py.builtins
                                val list = mutableListOf<Map<String, Any?>>()
                                for (item in pyResults.asList()) {
                                    val map = item.asMap()
                                    val strTitle    = builtins.callAttr("str", "title")
                                    val strUploader = builtins.callAttr("str", "uploader")
                                    val strUrl      = builtins.callAttr("str", "url")
                                    val strDuration = builtins.callAttr("str", "duration_seconds")
                                    list.add(mapOf(
                                        "title"            to map[strTitle]?.toString(),
                                        "uploader"         to map[strUploader]?.toString(),
                                        "url"              to map[strUrl]?.toString(),
                                        "duration_seconds" to
                                            map[strDuration]
                                                ?.toJava(Int::class.java),
                                    ))
                                }
                                withContext(Dispatchers.Main) { result.success(list) }
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

                        // Acknowledge immediately; progress comes via EventChannel
                        result.success(null)

                        val sink = activeSink
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                // KotlinEventSink is a plain Kotlin class.
                                // Chaquopy lets Python call methods on Kotlin
                                // objects directly — no interface needed.
                                bridge.callAttr(
                                    "download",
                                    url,
                                    outputDir,
                                    KotlinEventSink(sink),
                                )
                            } catch (e: Exception) {
                                Handler(Looper.getMainLooper()).post {
                                    sink?.success("error:${e.message}")
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
 * Must marshal back to the main thread because Flutter channel calls
 * are not thread-safe.
 */
class KotlinEventSink(private val sink: EventChannel.EventSink?) {
    fun success(message: String) {
        Handler(Looper.getMainLooper()).post {
            sink?.success(message)
        }
    }
}