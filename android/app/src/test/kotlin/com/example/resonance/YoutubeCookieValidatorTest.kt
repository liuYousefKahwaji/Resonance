package com.example.resonance

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class YoutubeCookieValidatorTest {
    @Test
    fun acceptsYoutubeHttpOnlyCookies() {
        val value = "\uFEFF# Netscape HTTP Cookie File\r\n" +
            "#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t0\tLOGIN_INFO\tfake-login\r\n" +
            ".youtube.com\tTRUE\t/\tTRUE\t0\t__Secure-3PAPISID\tfake-sapisid\r\n"
        val result = YoutubeCookieValidator.validate(value.toByteArray())
        assertEquals(2, result.cookieCount)
        assertTrue("youtube.com" in result.domains)
    }

    @Test(expected = YoutubeCookieValidationException::class)
    fun rejectsNonYoutubeCookies() {
        YoutubeCookieValidator.validate(
            ("# HTTP Cookie File\n" +
                ".example.com\tTRUE\t/\tTRUE\t0\tFAKE\tvalue\n").toByteArray(),
        )
    }

    @Test(expected = YoutubeCookieValidationException::class)
    fun rejectsOversizeFiles() {
        YoutubeCookieValidator.validate(ByteArray(YoutubeCookieValidator.MAX_BYTES + 1))
    }

    @Test(expected = YoutubeCookieValidationException::class)
    fun rejectsSignedOutYoutubeCookies() {
        YoutubeCookieValidator.validate(
            ("# Netscape HTTP Cookie File\n" +
                ".youtube.com\tTRUE\t/\tTRUE\t0\tPREF\tfake\n").toByteArray(),
        )
    }
}
