package com.example.resonance

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Owns Android microphone or playback capture while Resonance is in the
 * background. Both modes use a foreground service on current Android releases.
 */
class MusicRecognitionCaptureService : Service() {
    fun interface CaptureCallback {
        fun onComplete(bytes: ByteArray?, errorCode: String?, errorMessage: String?)
    }

    companion object {
        private const val ACTION_CAPTURE_DEVICE_AUDIO =
            "com.example.resonance.action.CAPTURE_DEVICE_AUDIO"
        private const val ACTION_CAPTURE_MICROPHONE =
            "com.example.resonance.action.CAPTURE_MICROPHONE"
        private const val ACTION_CANCEL = "com.example.resonance.action.CANCEL_AUDIO_CAPTURE"
        private const val EXTRA_REQUEST_ID = "requestId"
        private const val EXTRA_RESULT_CODE = "resultCode"
        private const val EXTRA_PROJECTION_DATA = "projectionData"
        private const val EXTRA_CAPTURE_DURATION_MS = "captureDurationMs"
        private const val EXTRA_WAIT_TIMEOUT_MS = "waitTimeoutMs"
        private const val NOTIFICATION_CHANNEL_ID = "music_recognition_capture"
        private const val NOTIFICATION_ID = 23023

        private val requestSlot = AtomicReference<String?>(null)
        private val callbacks = ConcurrentHashMap<String, CaptureCallback>()
        private val cancelledRequests = Collections.synchronizedSet(mutableSetOf<String>())

        @Volatile
        private var instance: MusicRecognitionCaptureService? = null

        /** Returns false only when another recognition capture owns the service. */
        fun startCapture(
            context: Context,
            requestId: String,
            resultCode: Int,
            projectionData: Intent,
            captureDurationMs: Int,
            waitTimeoutMs: Int,
            callback: CaptureCallback,
        ): Boolean {
            if (!requestSlot.compareAndSet(null, requestId)) return false
            callbacks[requestId] = callback

            val serviceIntent = Intent(context, MusicRecognitionCaptureService::class.java).apply {
                action = ACTION_CAPTURE_DEVICE_AUDIO
                putExtra(EXTRA_REQUEST_ID, requestId)
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_PROJECTION_DATA, projectionData)
                putExtra(EXTRA_CAPTURE_DURATION_MS, captureDurationMs)
                putExtra(EXTRA_WAIT_TIMEOUT_MS, waitTimeoutMs)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            } catch (error: Throwable) {
                complete(
                    requestId,
                    null,
                    "CAPTURE_SERVICE_ERROR",
                    error.message ?: "Could not start the device-audio capture service",
                )
            }
            return true
        }

        /** Starts microphone capture in a foreground service for tile scans. */
        fun startMicrophoneCapture(
            context: Context,
            requestId: String,
            captureDurationMs: Int,
            callback: CaptureCallback,
        ): Boolean {
            if (!requestSlot.compareAndSet(null, requestId)) return false
            callbacks[requestId] = callback

            val serviceIntent = Intent(context, MusicRecognitionCaptureService::class.java).apply {
                action = ACTION_CAPTURE_MICROPHONE
                putExtra(EXTRA_REQUEST_ID, requestId)
                putExtra(EXTRA_CAPTURE_DURATION_MS, captureDurationMs)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            } catch (error: Throwable) {
                complete(
                    requestId,
                    null,
                    "CAPTURE_SERVICE_ERROR",
                    error.message ?: "Could not start the microphone capture service",
                )
            }
            return true
        }

        fun cancelCapture(requestId: String) {
            if (requestSlot.get() != requestId && instance?.activeRequestId != requestId) return
            cancelledRequests.add(requestId)
            instance?.cancelInternal(
                requestId,
                PcmCaptureFailure("CAPTURE_CANCELLED", "Music recognition was cancelled"),
            )
        }

        /** Last-resort ownership cleanup used by the Activity on every result. */
        fun releaseReservation(requestId: String) {
            cancelledRequests.remove(requestId)
            callbacks.remove(requestId)
            requestSlot.compareAndSet(requestId, null)
        }

        /** Clears a slot orphaned by service creation/destruction races. */
        fun releaseStaleReservation() {
            val requestId = requestSlot.get() ?: return
            val service = instance
            if (service == null || service.finished.get() || service.activeRequestId != requestId) {
                releaseReservation(requestId)
            }
        }

        private fun complete(
            requestId: String,
            bytes: ByteArray?,
            errorCode: String?,
            errorMessage: String?,
        ) {
            cancelledRequests.remove(requestId)
            requestSlot.compareAndSet(requestId, null)
            val callback = callbacks.remove(requestId) ?: return
            Handler(Looper.getMainLooper()).post {
                callback.onComplete(bytes, errorCode, errorMessage)
            }
        }
    }

    private val finished = AtomicBoolean(false)
    private val cancellation = AtomicReference<PcmCaptureFailure?>(null)
    private var activeRequestId: String? = null
    private var audioRecord: AudioRecord? = null
    private var mediaProjection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        ensureNotificationChannel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: activeRequestId
            if (requestId != null) {
                cancelCapture(requestId)
            }
            if (activeRequestId == null) stopSelf(startId)
            return START_NOT_STICKY
        }

        val requestId = intent?.getStringExtra(EXTRA_REQUEST_ID)
        val microphoneCapture = intent?.action == ACTION_CAPTURE_MICROPHONE
        val deviceAudioCapture = intent?.action == ACTION_CAPTURE_DEVICE_AUDIO
        if ((!microphoneCapture && !deviceAudioCapture) || requestId == null) {
            requestId?.let {
                complete(it, null, "CAPTURE_SERVICE_ERROR", "Invalid music-recognition capture request")
            }
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (activeRequestId != null || finished.get()) {
            complete(requestId, null, "CAPTURE_BUSY", "Another music-recognition capture is active")
            stopSelf()
            return START_NOT_STICKY
        }

        activeRequestId = requestId
        if (cancelledRequests.contains(requestId)) {
            finishWithError(
                PcmCaptureFailure("CAPTURE_CANCELLED", "Music recognition was cancelled"),
            )
            return START_NOT_STICKY
        }

        try {
            val notification = createNotification(requestId, microphoneCapture)
            if (deviceAudioCapture && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else if (microphoneCapture && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: Throwable) {
            finishWithError(
                PcmCaptureFailure(
                    "CAPTURE_SERVICE_ERROR",
                    error.message ?: "Could not show the music-recognition notification",
                ),
            )
            return START_NOT_STICKY
        }

        val captureDurationMs = intent.getIntExtra(EXTRA_CAPTURE_DURATION_MS, 8_000)
        if (microphoneCapture) {
            Thread({ captureMicrophone(captureDurationMs) }, "ResonanceMicrophoneCapture").start()
            return START_NOT_STICKY
        }

        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val projectionData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_PROJECTION_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_PROJECTION_DATA) as? Intent
        }
        val waitTimeoutMs = intent.getIntExtra(EXTRA_WAIT_TIMEOUT_MS, 20_000)
        if (projectionData == null) {
            finishWithError(
                PcmCaptureFailure("MEDIA_PROJECTION_ERROR", "Android did not return projection consent data"),
            )
            return START_NOT_STICKY
        }

        Thread({
            captureDeviceOutput(
                resultCode,
                projectionData,
                captureDurationMs,
                waitTimeoutMs,
            )
        }, "ResonanceDeviceAudioCapture").start()
        return START_NOT_STICKY
    }

    private fun captureMicrophone(captureDurationMs: Int) {
        try {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                throw PcmCaptureException(
                    PcmCaptureFailure("PERMISSION_DENIED", "Microphone permission is required to identify music"),
                )
            }
            cancellation.get()?.let { throw PcmCaptureException(it) }
            val record = PcmAudioCapture.createMicrophoneRecord()
            audioRecord = record
            val bytes = try {
                PcmAudioCapture.capture(
                    audioRecord = record,
                    captureDurationMs = captureDurationMs,
                    waitTimeoutMs = null,
                    cancellation = { cancellation.get() },
                )
            } finally {
                audioRecord = null
                record.release()
            }
            finishCapture(bytes, null)
        } catch (error: PcmCaptureException) {
            finishCapture(null, error.failure)
        } catch (error: SecurityException) {
            finishWithError(
                PcmCaptureFailure(
                    "PERMISSION_DENIED",
                    error.message ?: "Android blocked microphone capture",
                ),
            )
        } catch (error: Throwable) {
            finishWithError(
                PcmCaptureFailure(
                    "AUDIO_CAPTURE_FAILED",
                    error.message ?: "Microphone capture failed",
                ),
            )
        }
    }

    private fun captureDeviceOutput(
        resultCode: Int,
        projectionData: Intent,
        captureDurationMs: Int,
        waitTimeoutMs: Int,
    ) {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                throw PcmCaptureException(
                    PcmCaptureFailure(
                        "UNSUPPORTED_ANDROID_VERSION",
                        "Device-audio capture requires Android 10 or newer",
                    ),
                )
            }
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                throw PcmCaptureException(
                    PcmCaptureFailure("PERMISSION_DENIED", "Microphone permission is required for playback capture"),
                )
            }
            cancellation.get()?.let { throw PcmCaptureException(it) }

            val projectionManager =
                getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val projection = projectionManager.getMediaProjection(resultCode, projectionData)
                ?: throw PcmCaptureException(
                    PcmCaptureFailure(
                        "MEDIA_PROJECTION_ERROR",
                        "Android could not create the media-projection session",
                    ),
                )
            mediaProjection = projection
            val callback = object : MediaProjection.Callback() {
                override fun onStop() {
                    if (!finished.get()) {
                        cancelInternal(
                            checkNotNull(activeRequestId),
                            PcmCaptureFailure(
                                "MEDIA_PROJECTION_STOPPED",
                                "Android stopped device-audio sharing",
                            ),
                        )
                    }
                }
            }
            projectionCallback = callback
            projection.registerCallback(callback, Handler(Looper.getMainLooper()))

            val playbackConfig = AudioPlaybackCaptureConfiguration.Builder(projection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val record = PcmAudioCapture.createPlaybackRecord(playbackConfig)
            audioRecord = record
            val bytes = try {
                PcmAudioCapture.capture(
                    audioRecord = record,
                    captureDurationMs = captureDurationMs,
                    waitTimeoutMs = waitTimeoutMs,
                    cancellation = { cancellation.get() },
                )
            } finally {
                audioRecord = null
                record.release()
            }
            finishCapture(bytes, null)
        } catch (error: PcmCaptureException) {
            finishCapture(null, error.failure)
        } catch (error: SecurityException) {
            finishWithError(
                PcmCaptureFailure(
                    "MEDIA_PROJECTION_ERROR",
                    error.message ?: "Android rejected the media-projection session",
                ),
            )
        } catch (error: Throwable) {
            finishWithError(
                PcmCaptureFailure(
                    "AUDIO_CAPTURE_FAILED",
                    error.message ?: "Device-audio capture failed",
                ),
            )
        }
    }

    private fun cancelInternal(requestId: String, failure: PcmCaptureFailure) {
        if (requestId != activeRequestId || finished.get()) return
        cancellation.compareAndSet(null, failure)
        runCatching { audioRecord?.stop() }
    }

    private fun finishWithError(failure: PcmCaptureFailure) {
        finishCapture(null, failure)
    }

    private fun finishCapture(bytes: ByteArray?, failure: PcmCaptureFailure?) {
        if (!finished.compareAndSet(false, true)) return
        val requestId = activeRequestId ?: requestSlot.get()
        try {
            runCatching { audioRecord?.stop() }
            runCatching { audioRecord?.release() }
            audioRecord = null

            val projection = mediaProjection
            val callback = projectionCallback
            if (projection != null && callback != null) {
                runCatching { projection.unregisterCallback(callback) }
            }
            projectionCallback = null
            mediaProjection = null
            runCatching { projection?.stop() }

            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
            }
        } finally {
            activeRequestId = null
            if (requestId != null) {
                complete(requestId, bytes, failure?.code, failure?.message)
            }
            // A notification Cancel intent has a newer startId than the
            // capture request. stopSelfResult(oldId) leaves a finished service
            // alive forever, so terminate this one-shot service unconditionally.
            stopSelf()
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        activeRequestId?.let {
            cancelInternal(
                it,
                PcmCaptureFailure("CAPTURE_CANCELLED", "Music recognition was cancelled"),
            )
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (!finished.get()) {
            finishWithError(
                cancellation.get()
                    ?: PcmCaptureFailure("CAPTURE_CANCELLED", "Music recognition was cancelled"),
            )
        }
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Music recognition",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while Resonance listens for music in the background"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun createNotification(requestId: String, microphoneCapture: Boolean): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val openAppPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val cancelIntent = Intent(this, MusicRecognitionCaptureService::class.java).apply {
            action = ACTION_CANCEL
            putExtra(EXTRA_REQUEST_ID, requestId)
        }
        val cancelPendingIntent = PendingIntent.getService(
            this,
            requestId.hashCode(),
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_music_recognition_tile)
            .setContentTitle("Resonance is listening")
            .setContentText(
                if (microphoneCapture) {
                    "Listening through the microphone"
                } else {
                    "Play a song on this device to identify it"
                },
            )
            .setContentIntent(openAppPendingIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Cancel",
                cancelPendingIntent,
            )
            .build()
    }
}
