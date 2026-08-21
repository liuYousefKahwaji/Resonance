package com.example.resonance

import android.content.Context
import android.util.AtomicFile
import java.io.File

class YoutubeCookieStore(context: Context) {
    private val lock = Any()
    private val root = File(context.noBackupFilesDir, "resonance_youtube")
    private val canonical = File(root, "cookies.txt")
    private val workDirectory = File(root, "work")

    init {
        cleanupWorkingCopies()
    }

    fun status(): Map<String, Any?> = synchronized(lock) {
        val valid = canonical.takeIf { it.isFile }?.let {
            runCatching { YoutubeCookieValidator.validate(it.readBytes()) }.isSuccess
        } == true
        mapOf(
            "configured" to valid,
            "updatedAt" to if (valid) canonical.lastModified() else null,
            "sizeBytes" to if (valid) canonical.length() else 0L,
        )
    }

    fun import(bytes: ByteArray): Map<String, Any?> = synchronized(lock) {
        YoutubeCookieValidator.validate(bytes)
        root.mkdirs()
        val atomic = AtomicFile(canonical)
        val output = atomic.startWrite()
        try {
            output.write(bytes)
            output.flush()
            atomic.finishWrite(output)
        } catch (error: Throwable) {
            atomic.failWrite(output)
            throw error
        }
        status()
    }

    fun clear(): Map<String, Any?> = synchronized(lock) {
        if (canonical.exists() && !canonical.delete()) {
            throw IllegalStateException("Could not clear imported YouTube cookies")
        }
        cleanupWorkingCopies()
        status()
    }

    fun createWorkingCopy(): File? = synchronized(lock) {
        if (!canonical.isFile) return@synchronized null
        YoutubeCookieValidator.validate(canonical.readBytes())
        workDirectory.mkdirs()
        File.createTempFile("cookies-", ".txt", workDirectory).also { canonical.copyTo(it, overwrite = true) }
    }

    fun cleanupWorkingCopies() = synchronized(lock) {
        if (workDirectory.isDirectory) {
            workDirectory.listFiles()?.forEach { file -> runCatching { file.delete() } }
        }
    }
}
