package com.example.resonance

import android.media.audiofx.BassBoost
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Process-scoped BassBoost effects keyed by just_audio's real audio-session ID.
 * Keeping this outside MainActivity lets background playback retain the effect
 * when Android removes and later recreates the app task.
 */
object AndroidBassBoostBridge {
    private const val CHANNEL = "resonance/bass_boost"
    private val effects = mutableMapOf<Int, BassBoost>()

    @Synchronized
    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setStrength" -> {
                        val sessionId = (call.argument<Any>("audioSessionId") as? Number)?.toInt()
                        val strength = (call.argument<Any>("strength") as? Number)?.toDouble()
                        if (sessionId == null || sessionId <= 0 || strength == null) {
                            result.error("INVALID_ARGUMENT", "A valid audio session and strength are required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            if (strength <= 0.0) {
                                release(sessionId)
                                result.success(mapOf("applied" to false, "strengthSupported" to true))
                                return@setMethodCallHandler
                            }
                            val effect = effects.getOrPut(sessionId) { BassBoost(0, sessionId) }
                            val requested = (strength.coerceIn(0.0, 1.0) * 1000.0).toInt().toShort()
                            effect.setStrength(requested)
                            effect.enabled = true
                            result.success(
                                mapOf(
                                    "applied" to effect.enabled,
                                    "strengthSupported" to effect.strengthSupported,
                                    "roundedStrength" to effect.roundedStrength.toInt(),
                                ),
                            )
                        } catch (error: Throwable) {
                            release(sessionId)
                            result.error("BASS_BOOST_UNAVAILABLE", error.message ?: "Bass boost is unavailable", null)
                        }
                    }
                    "release" -> {
                        val sessionId = (call.argument<Any>("audioSessionId") as? Number)?.toInt()
                        if (sessionId != null) release(sessionId)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Synchronized
    private fun release(sessionId: Int) {
        effects.remove(sessionId)?.let { effect ->
            runCatching { effect.enabled = false }
            runCatching { effect.release() }
        }
    }
}
