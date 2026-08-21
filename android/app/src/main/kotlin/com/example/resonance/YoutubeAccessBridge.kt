package com.example.resonance

import com.chaquo.python.PyObject
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class YoutubeAccessBridge(
    private val activity: MainActivity,
    private val store: YoutubeCookieStore,
    private val pythonBridge: PyObject,
) {
    companion object {
        private const val CHANNEL = "resonance/youtube_access"
        private const val TEST_TARGET = "ytsearch1:YouTube music"
    }

    private val launcher = FirefoxLauncher(activity)

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> result.success(store.status())
                "importCookies" -> {
                    try {
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        result.success(store.import(bytes))
                    } catch (error: Exception) {
                        result.error("INVALID_COOKIE_FILE", error.message, null)
                    }
                }
                "clearCookies" -> runCatching { store.clear() }
                    .onSuccess(result::success)
                    .onFailure { result.error("CLEAR_ERROR", it.message, null) }
                "testCookies" -> {
                    val url = call.argument<String>("url") ?: TEST_TARGET
                    CoroutineScope(Dispatchers.IO).launch {
                        val working = runCatching { store.createWorkingCopy() }.getOrNull()
                        try {
                            if (working == null) throw IllegalStateException("No YouTube cookies are configured")
                            pythonBridge.callAttr("test_access", url, working.absolutePath)
                            withContext(Dispatchers.Main) {
                                result.success(mapOf("ok" to true, "testedAt" to System.currentTimeMillis()))
                            }
                        } catch (error: Exception) {
                            withContext(Dispatchers.Main) { result.error("TEST_ERROR", error.message, null) }
                        } finally {
                            working?.delete()
                        }
                    }
                }
                "isFirefoxInstalled" -> result.success(launcher.isInstalled())
                "openFirefoxUrl" -> runCatching {
                    launcher.openUrl(call.argument<String>("url") ?: "")
                }.onSuccess(result::success).onFailure { result.error("LAUNCH_ERROR", it.message, null) }
                "openYoutubeAppSettings" -> result.success(launcher.openYoutubeAppSettings())
                else -> result.notImplemented()
            }
        }
    }
}
