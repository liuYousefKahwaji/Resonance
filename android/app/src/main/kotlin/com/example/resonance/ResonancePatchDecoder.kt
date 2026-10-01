package com.example.resonance

object ResonancePatchDecoder {
    init { System.loadLibrary("resonance_update_patch") }
    external fun apply(source: String, patch: String, output: String, expectedSize: Long)
}
