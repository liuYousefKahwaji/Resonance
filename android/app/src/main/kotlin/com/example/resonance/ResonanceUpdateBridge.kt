package com.example.resonance

import android.app.DownloadManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.UUID

/** Durable, single-worker updater. The Dart boundary verifies the signed manifest;
 * this boundary independently checks installed identity and reconstructed APKs. */
object ResonanceUpdateBridge {
    private const val PREFS = "resonance_update"
    private const val CHANNEL_ID = "resonance_updates"
    private const val CERT = "d504a82e662a5a2596607084b2b64d84170519c3193fc7d7cc915bdfdc794fba"
    private const val RELEASE_PATH = "/liuYousefKahwaji/Resonance/releases/download/"
    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private var visibleActivity: WeakReference<MainActivity>? = null

    fun register(activity: MainActivity, engine: FlutterEngine) {
        visibleActivity = WeakReference(activity)
        MethodChannel(engine.dartExecutor.binaryMessenger, "resonance/app_update").setMethodCallHandler { call, result ->
            when (call.method) {
                "testAutoInstallRequested" -> {
                    if (!BuildConfig.RESONANCE_UPDATE_TEST) { result.notImplemented() }
                    else {
                        val requested = activity.intent.getBooleanExtra("resonance_update_test_install", false)
                        activity.intent.removeExtra("resonance_update_test_install")
                        result.success(requested)
                    }
                }
                "testRecordResult" -> {
                    if (!BuildConfig.RESONANCE_UPDATE_TEST) result.notImplemented()
                    else {
                        android.util.Log.i("ResonanceUpdateLab", call.arguments.toString())
                        result.success(null)
                    }
                }
                "canInstallUpdates" -> result.success(canInstall(activity))
                "pendingUpdateStatus" -> Thread {
                    try { val status = pendingStatus(activity); main.post { result.success(status) } }
                    catch (error: Exception) { main.post { result.error("UPDATE_STATUS", error.message, null) } }
                }.start()
                "retryPendingInstall" -> Thread {
                    try {
                        synchronized(lock) {
                            preferences(activity).getString("plan", null)?.let { accept(activity, JSONObject(it)) }
                        }
                        main.post { result.success(null) }
                    } catch (error: Exception) { main.post { result.error("UPDATE_ERROR", error.message, null) } }
                }.start()
                "installedUpdateIdentity" -> Thread {
                    try {
                        val info = installed(activity)
                        val identity = mapOf("packageName" to activity.packageName, "signingCertSha256" to certificate(info),
                            "sourceApkSha256" to hash(File(activity.applicationInfo.sourceDir)),
                            "hasSplits" to !activity.applicationInfo.splitSourceDirs.isNullOrEmpty())
                        main.post { result.success(identity) }
                    } catch (error: Exception) { main.post { result.error("UPDATE_IDENTITY", error.message, null) } }
                }.start()
                "downloadAndInstall" -> Thread {
                    try {
                        @Suppress("UNCHECKED_CAST")
                        val plan = JSONObject(call.arguments as Map<String, Any?>)
                        if (BuildConfig.RESONANCE_UPDATE_TEST && activity.intent.getBooleanExtra("resonance_update_test_require_approval", false)) {
                            plan.put("testRequireApproval", true)
                        }
                        synchronized(lock) { accept(activity, plan) }
                        main.post { result.success(null) }
                    } catch (error: Exception) { main.post { result.error("UPDATE_ERROR", error.message, null) } }
                }.start()
                "resumePendingInstall" -> {
                    scheduleInstallCheck(activity)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun preferences(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    // Read the durable snapshot without the worker lock: reconstruction may hold
    // it for seconds, and showing progress must never wait for that work.
    private fun pendingStatus(context: Context): Map<String, Any?>? {
        val prefs = preferences(context)
        val plan = prefs.getString("plan", null)?.let { JSONObject(it) } ?: return null
        if (plan.getLong("buildNumber") <= versionCode(installed(context))) return null
        var state = prefs.getString("state", "downloading") ?: "downloading"
        val full = prefs.getBoolean("full", false)
        val asset = if (full) plan.getJSONObject("full") else plan
        var received = 0L
        var total = asset.getLong("size")
        val id = prefs.getLong("download_id", -1)
        if (id >= 0 && state == "downloading") {
            downloads(context).query(DownloadManager.Query().setFilterById(id))?.use { cursor ->
                if (cursor.moveToFirst()) {
                    received = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                    val reportedTotal = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                    if (reportedTotal > 0) total = reportedTotal
                    state = when (cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))) {
                        DownloadManager.STATUS_PAUSED, DownloadManager.STATUS_PENDING -> "waiting"
                        DownloadManager.STATUS_FAILED -> "failed"
                        DownloadManager.STATUS_SUCCESSFUL -> "verifying"
                        else -> state
                    }
                }
            }
        }
        return mapOf("version" to plan.getString("version"), "state" to state, "received" to received,
            "total" to total, "full" to full, "retryRequired" to prefs.getBoolean("retry_required", false),
            "needsPermission" to !canInstall(context))
    }
    private fun canInstall(context: Context) = Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()
    fun activityResumed(context: Context) {
        if (canInstall(context) && preferences(context).contains("plan") && !preferences(context).getBoolean("retry_required", false)) scheduleInstallCheck(context)
    }
    private fun validHash(value: String) = Regex("[a-f0-9]{64}").matches(value)
    private fun validateAsset(asset: JSONObject) {
        val url = Uri.parse(asset.getString("url"))
        val local = BuildConfig.RESONANCE_UPDATE_TEST && url.scheme == "http" && url.host in listOf("127.0.0.1", "localhost", "10.0.2.2")
        require(local || (url.scheme == "https" && url.host == "github.com" && url.path.orEmpty().startsWith(RELEASE_PATH))) { "Untrusted update URL" }
        require(url.userInfo == null && url.fragment == null && validHash(asset.getString("sha256")) &&
            asset.getLong("size") in 1..(2L * 1024 * 1024 * 1024)) { "Invalid asset identity" }
    }
    private fun accept(context: Context, plan: JSONObject) {
        validateAsset(plan)
        val full = plan.getJSONObject("full"); validateAsset(full)
        require(plan.getString("packageName") == context.packageName && plan.getString("signingCertSha256") == CERT &&
            certificate(installed(context)) == CERT) { "Update signing identity differs" }
        require(plan.getLong("buildNumber") > versionCode(installed(context)) &&
            Regex("[0-9]+\\.[0-9]+\\.[0-9]+").matches(plan.getString("version")) &&
            plan.getString("targetApkSha256") == full.getString("sha256")) { "Invalid update version" }
        val prefs = preferences(context)
        val previous = prefs.getString("plan", null)?.let { JSONObject(it) }
        val retryFull = previous?.getString("targetApkSha256") == plan.getString("targetApkSha256") &&
            prefs.getBoolean("full", false) && prefs.getString("state", "") == "failed"
        if (previous?.getString("targetApkSha256") == plan.getString("targetApkSha256")) {
            val id = prefs.getLong("download_id", -1)
            if (id >= 0 && downloadStatus(context, id) != DownloadManager.STATUS_FAILED) { scheduleInstallCheck(context); return }
            if (prefs.getString("state", "") in listOf("ready", "installing", "awaiting_approval")) {
                prefs.edit().remove("retry_required").commit()
                scheduleInstallCheck(context); return
            }
        }
        val old = prefs.getLong("download_id", -1)
        if (old >= 0) downloads(context).remove(old)
        val oldSession = prefs.getInt("session_id", -1)
        if (oldSession >= 0) runCatching { context.packageManager.packageInstaller.abandonSession(oldSession) }
        prefs.edit().clear().putString("plan", plan.toString()).putString("generation", UUID.randomUUID().toString()).commit()
        enqueue(context, plan, full = plan.isNull("algorithm") || retryFull)
    }
    private fun downloads(context: Context) = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private fun enqueue(context: Context, plan: JSONObject, full: Boolean) {
        val prefs = preferences(context)
        val asset = if (full) plan.getJSONObject("full") else plan
        val directory = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: error("Download storage unavailable")
        val internal = File(context.noBackupFilesDir, "update").apply { mkdirs() }
        require(StatFs(directory.path).availableBytes > asset.getLong("size") + 8 * 1024 * 1024 &&
            StatFs(internal.path).availableBytes > plan.getJSONObject("full").getLong("size") + 16 * 1024 * 1024) { "Not enough space for the update" }
        val filename = "resonance-${UUID.randomUUID()}" + if (full) ".apk" else ".xdelta"
        val request = DownloadManager.Request(Uri.parse(asset.getString("url")))
            .setTitle("Resonance ${plan.getString("version")}")
            .setDescription(if (full) "Downloading full update" else "Downloading smaller update")
            .setMimeType(if (full) "application/vnd.android.package-archive" else "application/octet-stream")
            .setAllowedOverMetered(true).setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalFilesDir(context, Environment.DIRECTORY_DOWNLOADS, filename)
        // Persist intent before enqueue. A crash in this tiny interval is recovered
        // as an interrupted request; an orphan system download is never installed.
        prefs.edit().putString("state", "downloading").putBoolean("full", full)
            .putString("download_path", File(directory, filename).absolutePath).remove("download_id").commit()
        val id = downloads(context).enqueue(request)
        prefs.edit().putLong("download_id", id).commit()
        scheduleInstallCheck(context)
    }
    private fun downloadStatus(context: Context, id: Long): Int? = downloads(context).query(DownloadManager.Query().setFilterById(id))?.use {
        if (it.moveToFirst()) it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) else null
    }
    private fun fallback(context: Context, plan: JSONObject, reason: String) {
        val prefs = preferences(context)
        val id = prefs.getLong("download_id", -1); if (id >= 0) downloads(context).remove(id)
        if (prefs.getBoolean("full", false)) {
            prefs.edit().putString("state", "failed").remove("download_id").commit()
            notify(context, "Update could not be verified", "Open Resonance to try again", null)
        } else {
            notify(context, "Downloading full update", reason, null)
            enqueue(context, plan, full = true)
        }
    }
    fun resumePending(context: Context) = synchronized(lock) {
        val prefs = preferences(context)
        val raw = prefs.getString("plan", null) ?: return@synchronized
        val plan = JSONObject(raw)
        if (plan.getLong("buildNumber") <= versionCode(installed(context))) {
            cleanup(context); return@synchronized
        }
        if (prefs.getBoolean("retry_required", false)) return@synchronized
        val state = prefs.getString("state", "")
        if (BuildConfig.RESONANCE_UPDATE_TEST) android.util.Log.i("ResonanceUpdateLab", "worker state=$state full=${prefs.getBoolean("full", false)}")
        if (state == "installing" || state == "awaiting_approval") {
            val session = context.packageManager.packageInstaller.getSessionInfo(prefs.getInt("session_id", -1))
            if (session != null) {
                if (state == "awaiting_approval") {
                    val confirmation = prefs.getString("confirmation_intent", null)?.let {
                        runCatching { Intent.parseUri(it, Intent.URI_INTENT_SCHEME) }.getOrNull()
                    }
                    if (confirmation != null) showApproval(context, confirmation)
                    else readyForRetry(context)
                }
                return@synchronized
            }
            if (state == "awaiting_approval") {
                // Some installers discard a cancelled session without sending
                // a failure callback. Do not interpret that as a fresh retry.
                readyForRetry(context)
                return@synchronized
            }
            prefs.edit().putString("state", "ready").remove("session_id").remove("confirmation_intent").commit()
        }
        if (state == "failed") return@synchronized
        var apk: File
        if (state == "downloading" || state == "verifying" || state == "reconstructing") {
            val id = prefs.getLong("download_id", -1)
            val status = if (id >= 0) downloadStatus(context, id) else null
            if (status == DownloadManager.STATUS_PENDING || status == DownloadManager.STATUS_RUNNING || status == DownloadManager.STATUS_PAUSED) return@synchronized
            if (status != DownloadManager.STATUS_SUCCESSFUL) { fallback(context, plan, "Smaller download was interrupted"); return@synchronized }
            val asset = if (prefs.getBoolean("full", false)) plan.getJSONObject("full") else plan
            val payload = File(prefs.getString("download_path", "")!!)
            try {
                prefs.edit().putString("state", "verifying").commit()
                check(payload.isFile && payload.length() == asset.getLong("size") && hash(payload) == asset.getString("sha256")) { "Download checksum mismatch" }
                if (prefs.getBoolean("full", false)) {
                    val root = File(context.noBackupFilesDir, "update").apply { mkdirs() }
                    apk = File(root, "${prefs.getString("generation", "")}.apk")
                    val partial = File(root, "${prefs.getString("generation", "")}.apk.part")
                    payload.copyTo(partial, overwrite = true)
                    check(partial.renameTo(apk)) { "Cannot save verified APK" }
                } else {
                    check(plan.getString("algorithm") == "xdelta3-vcdiff" && context.applicationInfo.splitSourceDirs.isNullOrEmpty()) { "Patch is incompatible" }
                    val source = File(context.applicationInfo.sourceDir)
                    check(hash(source) == plan.getString("sourceApkSha256")) { "Installed APK changed" }
                    prefs.edit().putString("state", "reconstructing").commit()
                    val root = File(context.noBackupFilesDir, "update").apply { mkdirs() }
                    val partial = File(root, "${prefs.getString("generation", "")}.apk.part")
                    partial.delete()
                    ResonancePatchDecoder.apply(source.path, payload.path, partial.path, plan.getJSONObject("full").getLong("size"))
                    check(hash(partial) == plan.getString("targetApkSha256")) { "Reconstructed APK checksum mismatch" }
                    apk = File(root, "${prefs.getString("generation", "")}.apk")
                    check(partial.renameTo(apk)) { "Cannot save verified APK" }
                }
                verifyApk(context, apk, plan)
                if (BuildConfig.RESONANCE_UPDATE_TEST) android.util.Log.i("ResonanceUpdateLab", "Exact signed APK verified, version=${plan.getString("version")}")
                prefs.edit().putString("state", "ready").putString("apk_path", apk.path).remove("download_id").commit()
                downloads(context).remove(id)
            } catch (error: Exception) {
                if (Thread.currentThread().isInterrupted) throw error
                fallback(context, plan, "Using the verified full package instead"); return@synchronized
            }
        } else {
            apk = File(prefs.getString("apk_path", "")!!)
            try { verifyApk(context, apk, plan) }
            catch (error: Exception) {
                if (Thread.currentThread().isInterrupted) throw error
                fallback(context, plan, "Prepared update was interrupted; using a fresh full package")
                return@synchronized
            }
        }
        if (!canInstall(context)) {
            val permission = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val activity = visibleActivity?.get()
            if (activity?.isVisibleForUpdate() == true) main.post { activity.startActivity(permission) }
            else notify(context, "Update ready", "Allow Resonance to install this update", permission)
            return@synchronized
        }
        install(context, apk, plan)
    }
    private fun verifyApk(context: Context, file: File, plan: JSONObject) {
        val full = plan.getJSONObject("full")
        check(file.isFile && file.length() == full.getLong("size") && hash(file) == full.getString("sha256")) { "APK checksum mismatch" }
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageArchiveInfo(file.path, signingFlags()) ?: error("Unreadable APK")
        check(info.packageName == context.packageName && info.packageName == plan.getString("packageName") &&
            info.versionName == plan.getString("version") && versionCode(info) == plan.getLong("buildNumber") &&
            versionCode(info) > versionCode(installed(context)) && certificate(info) == plan.getString("signingCertSha256") &&
            certificate(info) == certificate(installed(context))) { "APK identity mismatch" }
    }
    @Suppress("DEPRECATION")
    private fun signingFlags() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    private fun installed(context: Context) = context.packageManager.getPackageInfo(context.packageName, signingFlags())
    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo) = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun certificate(info: PackageInfo): String {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        require(signatures?.size == 1) { "Unexpected APK signing identity" }
        return hex(MessageDigest.getInstance("SHA-256").digest(signatures!![0].toByteArray()))
    }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun hash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                check(!Thread.currentThread().isInterrupted) { "Verification interrupted" }
                val count = input.read(buffer); if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return hex(digest.digest())
    }
    private fun install(context: Context, file: File, plan: JSONObject) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName); setSize(file.length())
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(
                if (BuildConfig.RESONANCE_UPDATE_TEST && plan.optBoolean("testRequireApproval")) PackageInstaller.SessionParams.USER_ACTION_REQUIRED
                else PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val sessionId = installer.createSession(params)
        preferences(context).edit().putString("state", "installing").putInt("session_id", sessionId).remove("confirmation_intent").commit()
        try {
            installer.openSession(sessionId).use { session ->
                session.openWrite("base.apk", 0, file.length()).use { output ->
                    FileInputStream(file).use { it.copyTo(output) }; session.fsync(output)
                }
                val callback = Intent(context, ResonanceUpdateResultReceiver::class.java).apply { action = context.packageName + ".UPDATE_INSTALL_RESULT" }
                val pending = PendingIntent.getBroadcast(context, sessionId, callback, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                session.commit(pending.intentSender)
            }
        } catch (error: Exception) {
            installer.abandonSession(sessionId)
            preferences(context).edit().putString("state", "ready").remove("session_id").commit()
            throw error
        }
    }
    fun installResult(context: Context, intent: Intent) = synchronized(lock) {
        val callbackSession = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        if (callbackSession >= 0 && callbackSession != preferences(context).getInt("session_id", -1)) return@synchronized
        if (BuildConfig.RESONANCE_UPDATE_TEST) android.util.Log.i("ResonanceUpdateLab", "install status=${intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999)}")
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_SUCCESS -> cleanup(context)
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirmation = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java) else intent.getParcelableExtra(Intent.EXTRA_INTENT)
                if (confirmation != null) {
                    preferences(context).edit().putString("state", "awaiting_approval")
                        .putString("confirmation_intent", confirmation.toUri(Intent.URI_INTENT_SCHEME)).commit()
                    showApproval(context, confirmation)
                } else {
                    readyForRetry(context)
                    notify(context, "Finish installing Resonance", "Check for updates to retry installation", null)
                }
            }
            else -> {
                readyForRetry(context)
                notify(context, "Update could not be installed", "Open Resonance to try again", null)
            }
        }
    }
    private fun showApproval(context: Context, confirmation: Intent) {
        confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val activity = visibleActivity?.get()
        if (activity?.isVisibleForUpdate() == true) main.post {
            runCatching { activity.startActivity(confirmation) }.onFailure {
                // A stale OEM confirmation must never crash the player or leave
                // an unfinishable session. Keep the verified private APK ready.
                synchronized(lock) {
                    readyForRetry(context)
                }
                notify(context, "Update ready", "Check for updates to retry installation", null)
            }
        } else notify(context, "Finish installing Resonance", "Tap to approve the update", confirmation)
    }
    private fun readyForRetry(context: Context) {
        val prefs = preferences(context)
        val sessionId = prefs.getInt("session_id", -1)
        if (sessionId >= 0) runCatching { context.packageManager.packageInstaller.abandonSession(sessionId) }
        prefs.edit().putString("state", "ready").putBoolean("retry_required", true)
            .remove("session_id").remove("confirmation_intent").commit()
    }
    private fun cleanup(context: Context) {
        val prefs = preferences(context)
        val id = prefs.getLong("download_id", -1); if (id >= 0) downloads(context).remove(id)
        // Only private updater files; playlists/settings are never touched.
        File(context.noBackupFilesDir, "update").listFiles()?.filter { it.name.endsWith(".apk") || it.name.endsWith(".apk.part") }?.forEach { it.delete() }
        prefs.edit().clear().commit()
    }
    fun scheduleInstallCheck(context: Context) {
        (context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler).schedule(
            JobInfo.Builder(9401, ComponentName(context, ResonanceUpdateJobService::class.java)).setOverrideDeadline(0).build())
    }
    fun isInstallResult(context: Context, intent: Intent) = intent.action == context.packageName + ".UPDATE_INSTALL_RESULT"
    private fun notify(context: Context, title: String, message: String, confirmation: Intent?) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "App updates", NotificationManager.IMPORTANCE_HIGH))
        val open = confirmation ?: context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pending = open?.let { PendingIntent.getActivity(context, 9401, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
        runCatching { manager.notify(9401, NotificationCompat.Builder(context, CHANNEL_ID).setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title).setContentText(message).setAutoCancel(true).setPriority(NotificationCompat.PRIORITY_HIGH).setContentIntent(pending).build()) }
    }
}

class ResonanceUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == DownloadManager.ACTION_DOWNLOAD_COMPLETE &&
            context.getSharedPreferences("resonance_update", Context.MODE_PRIVATE).getLong("download_id", -1) == intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)) {
            ResonanceUpdateBridge.scheduleInstallCheck(context)
        }
    }
}
class ResonanceUpdateResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (ResonanceUpdateBridge.isInstallResult(context, intent)) ResonanceUpdateBridge.installResult(context, intent)
    }
}
class ResonanceUpdateJobService : JobService() {
    private var worker: Thread? = null
    override fun onStartJob(params: JobParameters): Boolean {
        worker = Thread {
            var retry = false
            try { ResonanceUpdateBridge.resumePending(this) }
            catch (_: Exception) { retry = true }
            finally { jobFinished(params, retry) }
        }.apply { start() }
        return true
    }
    override fun onStopJob(params: JobParameters): Boolean { worker?.interrupt(); return true }
}
