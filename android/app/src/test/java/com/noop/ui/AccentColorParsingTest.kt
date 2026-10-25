package com.noop.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Test

class AccentColorParsingTest {
    private val fallback = Color(0xFF149A78)

    @Test
    fun `six RGB digits resolve to an opaque color`() {
        for (input in listOf("#A844CC", "a844cc", "  #a844cc  ", " A844CC ")) {
            assertEquals(input, Color(0xFFA844CC), AccentColor.parseHex(input, fallback))
        }
        assertEquals(Color.Black, AccentColor.parseHex("#000000", fallback))
        assertEquals(Color.White, AccentColor.parseHex("#FFFFFF", fallback))
    }

    @Test
    fun `malformed values use the supplied fallback instead of an unintended color`() {
        for (input in listOf("", "#", "#ABC", "12345", "1234567", "#FFA844CC", "+12345", "-12345", "#GG0000", "#12 3456", "##123456")) {
            assertEquals(input, fallback, AccentColor.parseHex(input, fallback))
        }
    }
}
