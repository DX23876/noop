package com.noop.ui

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class MaterialAccentSchemeTest {
    private val originalTokens = Palette.active
    private val originalAccent = AccentPrefs.color
    private val originalHex = AccentPrefs.customHex

    @After
    fun restorePreferences() {
        val context = RuntimeEnvironment.getApplication()
        AccentPrefs.setColor(context, originalAccent)
        AccentPrefs.setCustomHex(context, originalHex)
        Palette.active = originalTokens
    }

    @Test
    fun `Material controls follow every selected accent in both appearances`() {
        val context = RuntimeEnvironment.getApplication()
        AccentPrefs.setCustomHex(context, "#A844CC")
        for (dark in listOf(false, true)) {
            val tokens = if (dark) DarkTokens else LightTokens
            Palette.active = tokens
            for (accent in AccentColor.entries) {
                AccentPrefs.setColor(context, accent)
                val scheme = noopColorScheme(tokens, dark)
                assertEquals("primary: $accent, dark=$dark", Palette.accent, scheme.primary)
                assertEquals(Palette.accentMuted, scheme.primaryContainer)
                assertEquals(if (dark) Palette.accentHover else Palette.accent, scheme.onPrimaryContainer)
                // Picking a chrome accent must not recolor metric or warning semantics.
                assertEquals(tokens.metricPurple, scheme.secondary)
                assertEquals(tokens.statusCritical, scheme.error)
            }
        }
    }
}
