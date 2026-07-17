package com.example.resonance

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONObject
import java.util.UUID

/**
 * Process-independent state shared by the Flutter recognition flow, the Quick
 * Settings tile, and completion notifications.
 *
 * SharedPreferences is intentional here: a result notification must still be
 * useful after Android recreates [MainActivity], and a tile service may be
 * rebound without the activity process state that started a scan.
 */
object MusicRecognitionCoordinator {
    const val ACTION_START_RECOGNITION =
        "com.example.resonance.action.START_MUSIC_RECOGNITION"
    const val ACTION_OPEN_RECOGNITION_PICKER =
        "com.example.resonance.action.OPEN_MUSIC_RECOGNITION_PICKER"
    const val ACTION_OPEN_RECOGNITION_RESULT =
        "com.example.resonance.action.OPEN_MUSIC_RECOGNITION_RESULT"
    const val ACTION_DISMISS_RECOGNITION_RESULT =
        "com.example.resonance.action.DISMISS_MUSIC_RECOGNITION_RESULT"

    const val EXTRA_SOURCE = "recognitionSource"
    const val EXTRA_FROM_TILE = "recognitionFromTile"
    const val EXTRA_MINIMIZED_TILE_LAUNCH = "recognitionMinimizedTileLaunch"
    const val EXTRA_RESULT_ID = "recognitionResultId"

    private const val PREFS_NAME = "resonance_music_recognition"
    private const val KEY_DEFAULT_SOURCE = "defaultSource"
    private const val KEY_SCAN_ACTIVE = "scanActive"
    private const val KEY_SCAN_ORIGIN = "scanOrigin"
    private const val KEY_SCAN_STAGE = "scanStage"
    private const val KEY_SCAN_STARTED_AT = "scanStartedAt"
    private const val KEY_PENDING_ACTION = "pendingAction"
    private const val KEY_PENDING_RESULT = "pendingResult"
    private const val ORIGIN_TILE = "tile"
    private const val ORIGIN_APP = "app"
    private const val STALE_SCAN_AFTER_MS = 2 * 60 * 1000L

    // Channel importance cannot be raised after Android creates a channel. Use
    // a versioned ID so installs which received the old DEFAULT-importance
    // channel are migrated to the heads-up capable channel exactly once.
    private const val LEGACY_RESULT_CHANNEL_ID = "music_recognition_results"
    private const val RESULT_CHANNEL_ID = "music_recognition_results_v2"
    const val RESULT_NOTIFICATION_ID = 23024

    @Volatile
    private var activityVisible = false

    data class TileSnapshot(
        val active: Boolean,
        val origin: String,
        val stage: String,
    )

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun setActivityVisible(visible: Boolean) {
        activityVisible = visible
    }

    fun getDefaultSource(context: Context): String =
        prefs(context).getString(KEY_DEFAULT_SOURCE, "microphone")
            ?.takeIf { it == "microphone" || it == "deviceOutput" }
            ?: "microphone"

    fun setDefaultSource(context: Context, source: String) {
        require(source == "microphone" || source == "deviceOutput")
        prefs(context).edit().putString(KEY_DEFAULT_SOURCE, source).apply()
    }

    @Synchronized
    fun reserveTileScan(context: Context): Boolean {
        clearStaleScan(context)
        if (prefs(context).getBoolean(KEY_SCAN_ACTIVE, false)) return false
        prefs(context).edit()
            .putBoolean(KEY_SCAN_ACTIVE, true)
            .putString(KEY_SCAN_ORIGIN, ORIGIN_TILE)
            .putString(KEY_SCAN_STAGE, "launching")
            .putLong(KEY_SCAN_STARTED_AT, System.currentTimeMillis())
            .commit()
        requestTileUpdate(context)
        return true
    }

    /** Claims the global scan slot. A reserved tile launch may claim its slot once. */
    @Synchronized
    fun beginScan(context: Context, fromTile: Boolean): Boolean {
        ensureResultNotificationChannel(context)
        clearStaleScan(context)
        val state = prefs(context)
        if (state.getBoolean(KEY_SCAN_ACTIVE, false)) {
            val reservedTile = fromTile &&
                state.getString(KEY_SCAN_ORIGIN, null) == ORIGIN_TILE &&
                state.getString(KEY_SCAN_STAGE, null) == "launching"
            if (!reservedTile) return false
            state.edit().putString(KEY_SCAN_STAGE, "listening").apply()
            requestTileUpdate(context)
            return true
        }

        // The coordinator is idle, so any native capture owner left behind by
        // a destroyed one-shot service is necessarily stale.
        MusicRecognitionCaptureService.releaseStaleReservation()
        state.edit()
            .putBoolean(KEY_SCAN_ACTIVE, true)
            .putString(KEY_SCAN_ORIGIN, if (fromTile) ORIGIN_TILE else ORIGIN_APP)
            .putString(KEY_SCAN_STAGE, "listening")
            .putLong(KEY_SCAN_STARTED_AT, System.currentTimeMillis())
            .apply()
        requestTileUpdate(context)
        return true
    }

    fun updateStage(context: Context, stage: String) {
        if (!prefs(context).getBoolean(KEY_SCAN_ACTIVE, false)) return
        prefs(context).edit().putString(KEY_SCAN_STAGE, stage).apply()
        requestTileUpdate(context)
    }

    fun isTileScanActive(context: Context): Boolean {
        clearStaleScan(context)
        val state = prefs(context)
        return state.getBoolean(KEY_SCAN_ACTIVE, false) &&
            state.getString(KEY_SCAN_ORIGIN, null) == ORIGIN_TILE
    }

    fun tileSnapshot(context: Context): TileSnapshot {
        clearStaleScan(context)
        val state = prefs(context)
        return TileSnapshot(
            active = state.getBoolean(KEY_SCAN_ACTIVE, false),
            origin = state.getString(KEY_SCAN_ORIGIN, "") ?: "",
            stage = state.getString(KEY_SCAN_STAGE, "idle") ?: "idle",
        )
    }

    /**
     * Completes the global scan and, when Resonance is backgrounded, persists
     * and posts a tappable outcome. Returns true when Flutter should defer UI
     * routing to that notification.
     */
    @Synchronized
    fun finishScan(context: Context, outcome: Map<String, Any?>): Boolean {
        // A cancellation callback and the recognition future can finish at
        // nearly the same time. Only the owner of an active scan may publish a
        // result; late callbacks reuse the already-persisted routing decision.
        if (!prefs(context).getBoolean(KEY_SCAN_ACTIVE, false)) {
            return !activityVisible && pendingResultAction(context) != null
        }
        clearScanState(context)
        if (activityVisible && outcome["canOpenDirectly"] != false) {
            clearPendingResult(context, null)
            requestTileUpdate(context)
            return false
        }

        val stored = outcome.toMutableMap().apply {
            put("kind", "recognitionResult")
            put("id", UUID.randomUUID().toString())
        }
        // apply() updates the in-process value synchronously without delaying
        // the heads-up notification on a disk fsync.
        prefs(context).edit().putString(KEY_PENDING_RESULT, JSONObject(stored).toString()).apply()
        // Keep the result even when notification permission/channel settings
        // prevent a visible notification. MainActivity will deliver it the next
        // time the user returns instead of losing a completed background scan.
        postResultNotification(context, stored)
        requestTileUpdate(context)
        return true
    }

    @Synchronized
    fun resetScan(context: Context) {
        clearScanState(context)
        requestTileUpdate(context)
    }

    private fun clearScanState(context: Context) {
        prefs(context).edit()
            .remove(KEY_SCAN_ACTIVE)
            .remove(KEY_SCAN_ORIGIN)
            .remove(KEY_SCAN_STAGE)
            .remove(KEY_SCAN_STARTED_AT)
            .apply()
    }

    fun enqueueLaunchAction(context: Context, action: Map<String, Any?>): Map<String, Any?> {
        val identified = action.toMutableMap().apply {
            if (this["id"] == null) put("id", UUID.randomUUID().toString())
        }
        prefs(context).edit().putString(KEY_PENDING_ACTION, JSONObject(identified).toString()).commit()
        return identified
    }

    fun pendingLaunchAction(context: Context): Map<String, Any?>? =
        prefs(context).getString(KEY_PENDING_ACTION, null)?.let(::jsonToMap)

    fun acknowledgeLaunchAction(context: Context, id: String?) {
        val pending = pendingLaunchAction(context) ?: return
        if (id == null || pending["id"] == id) {
            prefs(context).edit().remove(KEY_PENDING_ACTION).apply()
        }
    }

    fun pendingResultAction(context: Context): Map<String, Any?>? =
        prefs(context).getString(KEY_PENDING_RESULT, null)?.let(::jsonToMap)

    fun clearPendingResult(context: Context, id: String?) {
        val pending = pendingResultAction(context)
        if (id == null || pending == null || pending["id"] == id) {
            prefs(context).edit().remove(KEY_PENDING_RESULT).apply()
            context.getSystemService(NotificationManager::class.java)
                .cancel(RESULT_NOTIFICATION_ID)
        }
    }

    private fun postResultNotification(context: Context, outcome: Map<String, Any?>): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }

        val manager = context.getSystemService(NotificationManager::class.java)
        ensureResultNotificationChannel(context)

        val resultId = outcome["id"]?.toString() ?: return false
        val openIntent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_OPEN_RECOGNITION_RESULT
            putExtra(EXTRA_RESULT_ID, resultId)
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val openPendingIntent = PendingIntent.getActivity(
            context,
            resultId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val dismissIntent = Intent(context, MusicRecognitionNotificationDismissReceiver::class.java).apply {
            action = ACTION_DISMISS_RECOGNITION_RESULT
            putExtra(EXTRA_RESULT_ID, resultId)
        }
        val dismissPendingIntent = PendingIntent.getBroadcast(
            context,
            resultId.hashCode(),
            dismissIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val success = outcome["success"] == true
        val title = if (success) {
            outcome["title"]?.toString()?.ifBlank { "Song identified" } ?: "Song identified"
        } else {
            "Song not identified"
        }
        val text = if (success) {
            outcome["artist"]?.toString()?.ifBlank { "Tap to view the result" }
                ?: "Tap to view the result"
        } else {
            outcome["message"]?.toString()?.ifBlank { "Recognition did not return a result." }
                ?: "Recognition did not return a result."
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, RESULT_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_music_recognition_tile)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(openPendingIntent)
            .setDeleteIntent(dismissPendingIntent)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .setPriority(Notification.PRIORITY_HIGH)
            .setDefaults(Notification.DEFAULT_ALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build()
        return runCatching {
            manager.notify(RESULT_NOTIFICATION_ID, notification)
            true
        }.getOrDefault(false)
    }

    private fun ensureResultNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(RESULT_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    RESULT_CHANNEL_ID,
                    "Music recognition results",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Immediate results from background music recognition"
                    enableLights(true)
                    enableVibration(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setShowBadge(true)
                },
            )
        }
        if (manager.getNotificationChannel(LEGACY_RESULT_CHANNEL_ID) != null) {
            manager.deleteNotificationChannel(LEGACY_RESULT_CHANNEL_ID)
        }
    }

    private fun clearStaleScan(context: Context) {
        val state = prefs(context)
        if (!state.getBoolean(KEY_SCAN_ACTIVE, false)) return
        val startedAt = state.getLong(KEY_SCAN_STARTED_AT, 0L)
        if (startedAt <= 0L || System.currentTimeMillis() - startedAt > STALE_SCAN_AFTER_MS) {
            resetScan(context)
        }
    }

    private fun requestTileUpdate(context: Context) {
        MusicRecognitionTileService.requestUpdate(context.applicationContext)
    }

    private fun jsonToMap(raw: String): Map<String, Any?>? = runCatching {
        val json = JSONObject(raw)
        buildMap {
            val keys = json.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                put(key, json.opt(key).takeUnless { it === JSONObject.NULL })
            }
        }
    }.getOrNull()
}
