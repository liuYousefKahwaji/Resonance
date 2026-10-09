package com.example.resonance

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Streams large portable files through Android's system picker without Dart byte copies. */
class PortableFileExportBridge(private val activity: MainActivity) {
    private var pending: MethodChannel.Result? = null
    private var source: File? = null
    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "resonance/portable_export").setMethodCallHandler { call, result ->
            if (call.method != "save") { result.notImplemented(); return@setMethodCallHandler }
            if (pending != null) { result.error("BUSY", "A file picker is already open", null); return@setMethodCallHandler }
            val file = File(call.argument<String>("path") ?: "")
            if (!file.isFile || !file.canonicalPath.startsWith(activity.cacheDir.canonicalPath + File.separator)) {
                result.error("INVALID_FILE", "The temporary export file is unavailable", null); return@setMethodCallHandler
            }
            pending = result; source = file
            try {
                activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = call.argument<String>("mime") ?: "application/zip"
                    putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: file.name)
                }, REQUEST)
            } catch (error: Exception) {
                pending = null; source = null; result.error("EXPORT_ERROR", error.message, null)
            }
        }
    }
    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false
        val result = pending ?: return true
        val file = source
        pending = null; source = null
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null || file == null) { result.success(false); return true }
        CoroutineScope(Dispatchers.IO).launch {
            try {
                activity.contentResolver.openOutputStream(uri, "wt").use { output ->
                    requireNotNull(output) { "Could not open the selected destination" }
                    file.inputStream().use { it.copyTo(output) }
                }
                withContext(Dispatchers.Main) { result.success(true) }
            } catch (error: Exception) {
                withContext(Dispatchers.Main) { result.error("EXPORT_ERROR", error.message, null) }
            }
        }
        return true
    }
    companion object { const val REQUEST = 4104 }
}
