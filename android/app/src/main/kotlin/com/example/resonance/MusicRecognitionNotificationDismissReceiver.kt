package com.example.resonance

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class MusicRecognitionNotificationDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != MusicRecognitionCoordinator.ACTION_DISMISS_RECOGNITION_RESULT) return
        MusicRecognitionCoordinator.clearPendingResult(
            context,
            intent.getStringExtra(MusicRecognitionCoordinator.EXTRA_RESULT_ID),
        )
    }
}
