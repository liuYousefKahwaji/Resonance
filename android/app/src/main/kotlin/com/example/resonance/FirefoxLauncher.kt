package com.example.resonance

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.Settings

class FirefoxLauncher(private val activity: Activity) {
    private val firefoxPackages = listOf("org.mozilla.firefox", "org.mozilla.firefox_beta", "org.mozilla.fenix")
    private val allowedHosts = setOf("play.google.com", "support.mozilla.org", "addons.mozilla.org", "www.youtube.com")

    fun isInstalled(): Boolean = installedPackage() != null

    fun openUrl(rawUrl: String): Map<String, Any?> {
        val uri = Uri.parse(rawUrl)
        require(uri.scheme == "https" && uri.host?.lowercase() in allowedHosts) { "This tutorial link is not allowed." }
        val packageName = installedPackage()
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
            if (packageName != null && uri.host != "play.google.com") setPackage(packageName)
        }
        return try {
            activity.startActivity(intent)
            mapOf("launched" to true, "package" to packageName)
        } catch (_: ActivityNotFoundException) {
            mapOf("launched" to false, "package" to packageName)
        }
    }

    fun openYoutubeAppSettings(): Boolean = try {
        activity.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:com.google.android.youtube")),
        )
        true
    } catch (_: ActivityNotFoundException) {
        false
    }

    private fun installedPackage(): String? = firefoxPackages.firstOrNull { packageName ->
        runCatching { activity.packageManager.getPackageInfo(packageName, 0) }.isSuccess
    }
}
