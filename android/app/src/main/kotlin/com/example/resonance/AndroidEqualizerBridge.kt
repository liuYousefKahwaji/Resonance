package com.example.resonance

import android.media.audiofx.Equalizer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.roundToInt

/** Applies gains in millibels to the actual Android output session. */
object AndroidEqualizerBridge {
    private val effects = mutableMapOf<Int, Equalizer>()
    private val frequencies = doubleArrayOf(60.0, 230.0, 910.0, 3600.0, 12000.0)

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "resonance/equalizer")
            .setMethodCallHandler { call, result ->
                val id = call.argument<Number>("sessionId")?.toInt()
                if (id == null || id <= 0) {
                    result.error("INVALID_SESSION", "No active Android audio session", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "release" -> {
                        release(id)
                        result.success(null)
                    }
                    "apply" -> {
                        val gains = call.argument<List<Number>>("gains")
                        if (gains == null || gains.size != frequencies.size ||
                            gains.any { !it.toDouble().isFinite() || abs(it.toDouble()) > 10 }) {
                            result.error("INVALID_GAIN", "Five finite equalizer gains are required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val effect = effects.getOrPut(id) { Equalizer(0, id) }
                            check(effect.hasControl() && effect.numberOfBands > 0)
                            val range = effect.bandLevelRange
                            for (index in 0 until effect.numberOfBands.toInt()) {
                                val band = index.toShort()
                                val frequency = effect.getCenterFreq(band) / 1000.0
                                val millibels = (interpolate(frequency, gains) * 100).roundToInt()
                                    .coerceIn(range[0].toInt(), range[1].toInt()).toShort()
                                effect.setBandLevel(band, millibels)
                                check(abs(effect.getBandLevel(band).toInt() - millibels.toInt()) <= 100)
                            }
                            check(effect.setEnabled(true) == 0 && effect.enabled)
                            result.success(true)
                        } catch (_: Exception) {
                            release(id)
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun release(id: Int) {
        effects.remove(id)?.let {
            runCatching { it.setEnabled(false) }
            runCatching { it.release() }
        }
    }

    private fun interpolate(hz: Double, gains: List<Number>): Double {
        val upper = frequencies.indexOfFirst { hz <= it }
        if (upper < 0) return gains.last().toDouble()
        if (upper == 0) return gains.first().toDouble()
        val lower = frequencies[upper - 1]
        val fraction = ln(hz / lower) / ln(frequencies[upper] / lower)
        val lowGain = gains[upper - 1].toDouble()
        return lowGain + (gains[upper].toDouble() - lowGain) * fraction
    }
}
