package com.example.resonance

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Entry point used by SystemUI when the recognition tile is long-pressed. */
class MusicRecognitionTilePreferencesActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(
            Intent(this, MainActivity::class.java).apply {
                action = MusicRecognitionCoordinator.ACTION_OPEN_RECOGNITION_PICKER
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
        )
        finish()
    }
}
