package com.example.resonance

import android.Manifest
import android.app.DownloadManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.lang.ref.WeakReference

object ResonanceUpdateBridge {
    private const val CHANNEL = "resonance/app_update"
    private const val PREFS = "resonance_update"
    private const val CHANNEL_ID = "resonance_updates"
    private const val ACTION_INSTALL_RESULT = "com.example.resonance.UPDATE_INSTALL_RESULT"
    private var visibleActivity: WeakReference<MainActivity>? = null

    fun register(activity: MainActivity, engine: FlutterEngine) {
        visibleActivity = WeakReference(activity)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstallUpdates" -> result.success(
                    Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()
                )
                "downloadAndInstall" -> {
                    try {
                        val rawUrl = call.argument<String>("url") ?: error("Missing download URL")
                        val sha = call.argument<String>("sha256") ?: error("Missing checksum")
                        val version = call.argument<String>("version") ?: error("Missing version")
                        val size = call.argument<Number>("size")?.toLong() ?: error("Missing size")
                        val url = Uri.parse(rawUrl)
                        require(url.scheme == "https" && url.host == "github.com") { "Invalid update host" }
                        require(Regex("[a-fA-F0-9]{64}").matches(sha)) { "Invalid checksum" }
                        require(Regex("[0-9]+\\.[0-9]+\\.[0-9]+").matches(version)) { "Invalid version" }
                        require(size > 0) { "Invalid size" }
                        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                            val settings = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${activity.packageName}"))
                            activity.startActivity(settings)
                            result.error("INSTALL_PERMISSION", "Allow Resonance to install updates, then try again.", null)
                            return@setMethodCallHandler
                        }
                        enqueue(activity, url, sha.lowercase(), version, size)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("UPDATE_ERROR", error.message, null)
                    }
                }
                "resumePendingInstall" -> {
                    try {
                        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        if (prefs.contains("sha256")) scheduleInstallCheck(activity)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("UPDATE_ERROR", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun enqueue(context: Context, url: Uri, sha: String, version: String, size: Long) {
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val existingId = prefs.getLong("download_id", -1)
        if (prefs.getString("version", null) == version) {
            if (existingId >= 0) return
            val pendingApk = File(prefs.getString("path", "") ?: "")
            if (pendingApk.isFile) {
                scheduleInstallCheck(context)
                return
            }
        }
        if (existingId >= 0) manager.remove(existingId)
        val directory = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: error("Download storage unavailable")
        val filename = "resonance-update-$version.apk"
        File(directory, filename).delete()
        val request = DownloadManager.Request(url)
            .setTitle("Resonance $version")
            .setDescription("Downloading app update")
            .setMimeType("application/vnd.android.package-archive")
            .setAllowedOverMetered(true)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalFilesDir(context, Environment.DIRECTORY_DOWNLOADS, filename)
        val id = manager.enqueue(request)
        prefs.edit().putLong("download_id", id).putString("sha256", sha)
            .putString("version", version).putLong("size", size)
            .putString("path", File(directory, filename).absolutePath).apply()
    }

    fun downloadCompleted(context: Context, id: Long) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getLong("download_id", -1) != id) return
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        manager.query(DownloadManager.Query().setFilterById(id))?.use { cursor ->
            if (!cursor.moveToFirst()) return
            val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            if (status != DownloadManager.STATUS_SUCCESSFUL) {
                if (status == DownloadManager.STATUS_FAILED) {
                    prefs.edit().remove("download_id").apply()
                    notify(context, "Update download failed", "Open Resonance to try again", null)
                }
                return
            }
        }
        val file = File(prefs.getString("path", "") ?: "")
        val expectedHash = prefs.getString("sha256", null) ?: return
        val size = prefs.getLong("size", -1)
        if (!file.isFile || file.length() != size || hash(file) != expectedHash || !isNewResonanceApk(context, file)) {
            file.delete()
            prefs.edit().remove("download_id").apply()
            notify(context, "Update could not be verified", "Open Resonance to try again", null)
            return
        }
        prefs.edit().remove("download_id").apply()
        try {
            install(context, file)
        } catch (_: Exception) {
            notify(context, "Update ready to install", "Open Resonance to finish updating", null)
        }
    }

    fun resumePending(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val activeId = prefs.getLong("download_id", -1)
        if (activeId >= 0) {
            downloadCompleted(context, activeId)
            return
        }
        val file = File(prefs.getString("path", "") ?: "")
        val expected = prefs.getString("sha256", null)
        if (expected != null && file.isFile && file.length() == prefs.getLong("size", -1) &&
            isNewResonanceApk(context, file) && hash(file) == expected &&
            (Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls())) {
            install(context, file)
        } else if (expected != null && file.isFile &&
            (file.length() != prefs.getLong("size", -1) || hash(file) != expected)) {
            file.delete()
            prefs.edit().clear().apply()
        }
    }

    fun scheduleInstallCheck(context: Context) {
        val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
        val job = JobInfo.Builder(9401, ComponentName(context, ResonanceUpdateJobService::class.java))
            .setOverrideDeadline(0).build()
        scheduler.schedule(job)
    }

    private fun hash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }

    private fun isNewResonanceApk(context: Context, file: File): Boolean {
        @Suppress("DEPRECATION")
        val archive = context.packageManager.getPackageArchiveInfo(file.absolutePath, 0) ?: return false
        if (archive.packageName != context.packageName) return false
        @Suppress("DEPRECATION")
        val installed = context.packageManager.getPackageInfo(context.packageName, 0)
        val archiveVersion = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
        val installedVersion = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
        return archiveVersion > installedVersion
    }

    private fun install(context: Context, file: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= 31) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val sessionId = installer.createSession(params)
        try {
            installer.openSession(sessionId).use { session ->
                session.openWrite("base.apk", 0, file.length()).use { output ->
                    FileInputStream(file).use { input -> input.copyTo(output) }
                    session.fsync(output)
                }
                val callback = Intent(context, ResonanceUpdateResultReceiver::class.java).apply {
                    action = ACTION_INSTALL_RESULT
                    putExtra("path", file.absolutePath)
                }
                val pending = PendingIntent.getBroadcast(context, sessionId, callback,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                session.commit(pending.intentSender)
            }
        } catch (error: Exception) {
            installer.abandonSession(sessionId)
            throw error
        }
    }

    fun installResult(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        when (status) {
            PackageInstaller.STATUS_SUCCESS -> {
                intent.getStringExtra("path")?.let { File(it).delete() }
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
            }
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirmation = if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                else intent.getParcelableExtra(Intent.EXTRA_INTENT)
                confirmation?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                val activity = visibleActivity?.get()
                if (confirmation != null && activity?.isVisibleForUpdate() == true) {
                    activity.startActivity(confirmation)
                } else {
                    notify(context, "Finish installing Resonance", "Tap to approve the update", confirmation)
                }
            }
            else -> notify(context, "Update could not be installed", "Open Resonance to try again", null)
        }
    }

    private fun notify(context: Context, title: String, message: String, confirmation: Intent?) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "App updates", NotificationManager.IMPORTANCE_HIGH))
        }
        val open = confirmation ?: context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pending = open?.let {
            PendingIntent.getActivity(context, 9401, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(message)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pending)
            .build()
        manager.notify(9401, notification)
    }

    fun isInstallResult(intent: Intent) = intent.action == ACTION_INSTALL_RESULT
}

class ResonanceUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
        val prefs = context.getSharedPreferences("resonance_update", Context.MODE_PRIVATE)
        if (prefs.getLong("download_id", -1) == id) ResonanceUpdateBridge.scheduleInstallCheck(context)
    }
}

class ResonanceUpdateResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (ResonanceUpdateBridge.isInstallResult(intent)) ResonanceUpdateBridge.installResult(context, intent)
    }
}

class ResonanceUpdateJobService : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        Thread {
            try { ResonanceUpdateBridge.resumePending(this) }
            catch (_: Exception) { /* A later launch can retry the verified APK. */ }
            finally { jobFinished(params, false) }
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters) = true
}
