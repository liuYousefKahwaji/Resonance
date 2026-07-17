package com.example.resonance

import android.Manifest
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class MusicRecognitionTileService : TileService() {
    companion object {
        fun requestUpdate(context: Context) {
            runCatching {
                requestListeningState(
                    context,
                    ComponentName(context, MusicRecognitionTileService::class.java),
                )
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        renderState()
    }

    override fun onClick() {
        super.onClick()
        try {
            val snapshot = MusicRecognitionCoordinator.tileSnapshot(this)
            if (snapshot.active) {
                renderState()
                return
            }
            // Reserve only after a locked device is actually unlocked. The old
            // ordering left the tile permanently busy when unlock was cancelled.
            if (isLocked) {
                unlockAndRun(Runnable { launchRecognition() })
            } else {
                launchRecognition()
            }
        } catch (_: Throwable) {
            MusicRecognitionCoordinator.resetScan(this)
            renderState()
        }
    }

    private fun launchRecognition() {
        if (!MusicRecognitionCoordinator.reserveTileScan(this)) {
            renderState()
            return
        }

        val source = MusicRecognitionCoordinator.getDefaultSource(this)
        val notificationsReady =
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
                getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        val microphoneReady = source == "microphone" &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED &&
            notificationsReady
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            action = MusicRecognitionCoordinator.ACTION_START_RECOGNITION
            putExtra(MusicRecognitionCoordinator.EXTRA_SOURCE, source)
            putExtra(MusicRecognitionCoordinator.EXTRA_FROM_TILE, true)
            putExtra(MusicRecognitionCoordinator.EXTRA_MINIMIZED_TILE_LAUNCH, microphoneReady)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NO_ANIMATION
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val pendingIntent = PendingIntent.getActivity(
                    this,
                    27027,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                startActivityAndCollapse(pendingIntent)
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(launchIntent)
            }
        } catch (_: Throwable) {
            MusicRecognitionCoordinator.resetScan(this)
        }
        renderState()
    }

    private fun renderState() {
        val tile = qsTile ?: return
        val snapshot = MusicRecognitionCoordinator.tileSnapshot(this)
        val startedElsewhere = snapshot.active && snapshot.origin != "tile"
        val status = when {
            startedElsewhere -> "Scan in progress"
            !snapshot.active -> "Tap to identify"
            snapshot.stage == "fingerprinting" -> "Analyzing audio"
            snapshot.stage == "matching" -> "Finding song"
            snapshot.stage == "requestingPermission" -> "Permission needed"
            snapshot.stage == "waitingForAudio" -> "Waiting for audio"
            else -> "Listening"
        }
        tile.icon = Icon.createWithResource(this, R.drawable.ic_music_recognition_tile)
        tile.label = "Identify music"
        tile.state = when {
            startedElsewhere -> Tile.STATE_UNAVAILABLE
            snapshot.active -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.contentDescription = "Resonance music recognition. $status"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) tile.subtitle = status
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) tile.stateDescription = status
        tile.updateTile()
    }
}
