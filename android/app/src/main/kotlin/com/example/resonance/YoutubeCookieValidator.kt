package com.example.resonance

import java.nio.charset.StandardCharsets
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

data class YoutubeCookieValidation(
    val cookieCount: Int,
    val domains: Set<String>,
)

class YoutubeCookieValidationException(message: String) : IllegalArgumentException(message)

object YoutubeCookieValidator {
    const val MAX_BYTES = 1024 * 1024
    const val SIGNED_OUT_MESSAGE = "This export does not contain a signed-in YouTube session. Confirm your profile avatar is visible in the private tab, reload youtube.com/robots.txt, then export Current Site again."
    private val acceptedHeaders = setOf("# HTTP Cookie File", "# Netscape HTTP Cookie File")
    private val sapisidCookieNames = setOf("SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID")

    fun validate(bytes: ByteArray): YoutubeCookieValidation {
        if (bytes.isEmpty()) throw YoutubeCookieValidationException("This file is empty.")
        if (bytes.size > MAX_BYTES) {
            throw YoutubeCookieValidationException("This cookie file is too large. Do not export ALL sites.")
        }
        val text = try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
                .removePrefix("\uFEFF")
        } catch (_: Exception) {
            throw YoutubeCookieValidationException(
                "Choose the Netscape cookies.txt file downloaded by the Firefox add-on.",
            )
        }
        val lines = text.lineSequence().toList()
        val firstIndex = lines.indexOfFirst { it.isNotBlank() }
        if (firstIndex < 0) throw YoutubeCookieValidationException("This file is empty.")
        if (lines[firstIndex].trim() !in acceptedHeaders) {
            throw YoutubeCookieValidationException(
                "Choose the Netscape cookies.txt file downloaded by the Firefox add-on.",
            )
        }

        var cookieCount = 0
        var hasYoutube = false
        var hasLoginInfo = false
        var hasSapisid = false
        val domains = linkedSetOf<String>()
        lines.drop(firstIndex + 1).forEach { original ->
            if (original.isBlank()) return@forEach
            val line = when {
                original.startsWith("#HttpOnly_") -> original.removePrefix("#HttpOnly_")
                original.startsWith("#") -> return@forEach
                else -> original
            }
            val fields = line.split('\t')
            val valid = fields.size == 7 &&
                fields[1] in setOf("TRUE", "FALSE") &&
                fields[2].isNotEmpty() &&
                fields[3] in setOf("TRUE", "FALSE") &&
                fields[4].toLongOrNull() != null &&
                fields[5].isNotEmpty()
            if (!valid) {
                throw YoutubeCookieValidationException(
                    "Choose the Netscape cookies.txt file downloaded by the Firefox add-on.",
                )
            }
            val domain = fields[0].trim().lowercase().removePrefix(".")
            if (domain.isEmpty()) {
                throw YoutubeCookieValidationException(
                    "Choose the Netscape cookies.txt file downloaded by the Firefox add-on.",
                )
            }
            domains += domain
            val isYoutube = domain == "youtube.com" || domain.endsWith(".youtube.com")
            hasYoutube = hasYoutube || isYoutube
            if (isYoutube) {
                hasLoginInfo = hasLoginInfo || fields[5] == "LOGIN_INFO"
                hasSapisid = hasSapisid || fields[5] in sapisidCookieNames
            }
            cookieCount++
        }
        if (!hasYoutube) {
            throw YoutubeCookieValidationException(
                "This file does not contain YouTube cookies. Export Current Site while youtube.com/robots.txt is open.",
            )
        }
        if (!hasLoginInfo || !hasSapisid) {
            throw YoutubeCookieValidationException(SIGNED_OUT_MESSAGE)
        }
        return YoutubeCookieValidation(cookieCount, domains)
    }
}
