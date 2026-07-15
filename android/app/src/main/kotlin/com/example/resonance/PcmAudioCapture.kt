package com.example.resonance

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import java.io.ByteArrayOutputStream
import kotlin.math.min

internal data class PcmCaptureFailure(
    val code: String,
    val message: String,
)

internal class PcmCaptureException(
    val failure: PcmCaptureFailure,
    cause: Throwable? = null,
) : Exception(failure.message, cause)

/**
 * Creates and drains AudioRecord instances in the exact format expected by
 * the recognition layer: signed little-endian PCM16, mono, 16 kHz.
 */
internal object PcmAudioCapture {
    const val SAMPLE_RATE = 16_000
    const val BYTES_PER_SAMPLE = 2

    private const val DETECTION_CHUNK_BYTES = 3_200 // 100 ms at 16 kHz mono.
    private const val NON_SILENT_PEAK = 128
    private const val NON_SILENT_RMS_SQUARED = 32 * 32

    @SuppressLint("MissingPermission")
    fun createMicrophoneRecord(): AudioRecord =
        buildRecord { builder ->
            builder.setAudioSource(MediaRecorder.AudioSource.MIC)
        }

    @SuppressLint("MissingPermission")
    fun createPlaybackRecord(config: AudioPlaybackCaptureConfiguration): AudioRecord =
        buildRecord { builder ->
            builder.setAudioPlaybackCaptureConfig(config)
        }

    /**
     * Captures [captureDurationMs] once audio is present. When
     * [waitTimeoutMs] is null, recording begins immediately (microphone mode).
     * Otherwise leading digital silence is discarded until playback is heard.
     */
    fun capture(
        audioRecord: AudioRecord,
        captureDurationMs: Int,
        waitTimeoutMs: Int?,
        cancellation: () -> PcmCaptureFailure?,
    ): ByteArray {
        val targetByteCountLong =
            captureDurationMs.toLong() * SAMPLE_RATE * BYTES_PER_SAMPLE / 1_000L
        if (targetByteCountLong <= 0L || targetByteCountLong > Int.MAX_VALUE) {
            throw PcmCaptureException(
                PcmCaptureFailure("INVALID_ARGUMENT", "Invalid PCM capture duration"),
            )
        }
        val targetByteCount = targetByteCountLong.toInt().let { it - (it % BYTES_PER_SAMPLE) }
        val output = ByteArrayOutputStream(targetByteCount)
        val readBuffer = ByteArray(DETECTION_CHUNK_BYTES)
        val deadline = waitTimeoutMs?.let { SystemClock.elapsedRealtime() + it }
        var audioDetected = waitTimeoutMs == null

        cancellation()?.let { throw PcmCaptureException(it) }

        try {
            audioRecord.startRecording()
            if (audioRecord.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                throw PcmCaptureException(
                    PcmCaptureFailure("AUDIO_CAPTURE_FAILED", "Android could not start audio capture"),
                )
            }

            while (output.size() < targetByteCount) {
                cancellation()?.let { throw PcmCaptureException(it) }

                val bytesWanted = if (audioDetected) {
                    min(readBuffer.size, targetByteCount - output.size())
                } else {
                    readBuffer.size
                }
                val bytesRead = audioRecord.read(
                    readBuffer,
                    0,
                    bytesWanted,
                    AudioRecord.READ_BLOCKING,
                )

                cancellation()?.let { throw PcmCaptureException(it) }
                if (bytesRead <= 0) {
                    throw PcmCaptureException(
                        PcmCaptureFailure(
                            "AUDIO_CAPTURE_FAILED",
                            "Android audio capture stopped unexpectedly ($bytesRead)",
                        ),
                    )
                }

                if (!audioDetected) {
                    if (containsCapturableAudio(readBuffer, bytesRead)) {
                        audioDetected = true
                    } else if (SystemClock.elapsedRealtime() >= checkNotNull(deadline)) {
                        throw PcmCaptureException(
                            PcmCaptureFailure(
                                "NO_AUDIO_TIMEOUT",
                                "No capturable device audio was heard within ${waitTimeoutMs} ms",
                            ),
                        )
                    }
                }

                if (audioDetected) {
                    output.write(
                        readBuffer,
                        0,
                        min(bytesRead, targetByteCount - output.size()),
                    )
                }
            }
        } catch (error: PcmCaptureException) {
            throw error
        } catch (error: SecurityException) {
            throw PcmCaptureException(
                PcmCaptureFailure("PERMISSION_DENIED", "Audio capture permission was denied"),
                error,
            )
        } catch (error: Throwable) {
            cancellation()?.let { throw PcmCaptureException(it, error) }
            throw PcmCaptureException(
                PcmCaptureFailure(
                    "AUDIO_CAPTURE_FAILED",
                    error.message ?: "Android audio capture failed",
                ),
                error,
            )
        } finally {
            runCatching {
                if (audioRecord.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    audioRecord.stop()
                }
            }
        }

        return output.toByteArray()
    }

    @SuppressLint("MissingPermission")
    private fun buildRecord(configure: (AudioRecord.Builder) -> Unit): AudioRecord {
        val channelMask = AudioFormat.CHANNEL_IN_MONO
        val minBufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBufferSize <= 0) {
            throw PcmCaptureException(
                PcmCaptureFailure(
                    "AUDIO_FORMAT_UNSUPPORTED",
                    "This device does not support mono 16 kHz PCM capture",
                ),
            )
        }

        val builder = AudioRecord.Builder()
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(channelMask)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(minBufferSize, SAMPLE_RATE * BYTES_PER_SAMPLE))
        configure(builder)

        val record = try {
            builder.build()
        } catch (error: Throwable) {
            throw PcmCaptureException(
                PcmCaptureFailure(
                    "AUDIO_CAPTURE_FAILED",
                    error.message ?: "Android could not create an audio recorder",
                ),
                error,
            )
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw PcmCaptureException(
                PcmCaptureFailure("AUDIO_CAPTURE_FAILED", "Android audio recorder was not initialized"),
            )
        }
        return record
    }

    private fun containsCapturableAudio(bytes: ByteArray, byteCount: Int): Boolean {
        var peak = 0
        var sumSquares = 0L
        var samples = 0
        var index = 0
        while (index + 1 < byteCount) {
            val sample = (
                (bytes[index].toInt() and 0xff) or
                    (bytes[index + 1].toInt() shl 8)
                ).toShort().toInt()
            val absolute = if (sample == Short.MIN_VALUE.toInt()) 32_768 else kotlin.math.abs(sample)
            if (absolute > peak) peak = absolute
            sumSquares += sample.toLong() * sample.toLong()
            samples += 1
            index += BYTES_PER_SAMPLE
        }
        if (samples == 0) return false
        return peak >= NON_SILENT_PEAK || (sumSquares / samples) >= NON_SILENT_RMS_SQUARED
    }
}
