package com.example.resonance

import android.content.Context
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    // audio_service manages its own shared FlutterEngine so that the
    // audio background service and the UI activity use the SAME engine.
    // Without this override, audio_service throws:
    //   IllegalStateException: The Activity class declared in your
    //   AndroidManifest.xml is wrong or has not provided the correct FlutterEngine.
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return AudioServicePlugin.getFlutterEngine(context)
    }
}