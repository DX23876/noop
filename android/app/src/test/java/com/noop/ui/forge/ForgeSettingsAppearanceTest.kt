package com.noop.ui.forge

import com.noop.ui.ChartStyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The Theme preset a set of live settings stands for, as iOS's `ThemePreset.matching` reads them. */
class ForgeSettingsAppearanceTest {
    @Test fun eachRecipeMatchesItself() {
        ThemePresetChoice.entries.forEach { p ->
            val found = ThemePresetChoice.matching(p.accent, p.chart ?: ChartStyle.TITANIUM, p.sky, p.opacity)
            assertEquals(p, found)
        }
    }

    @Test fun anyOtherCombinationIsCustom() {
        assertNull(ThemePresetChoice.matching("mint", ChartStyle.TITANIUM, true, 70))
        assertNull(ThemePresetChoice.matching("custom", ChartStyle.TITANIUM, true, 100))
    }

    @Test fun theChartColoursSeparateOceanFromClassic() {
        assertEquals(ThemePresetChoice.Ocean, ThemePresetChoice.matching("whoopBlue", ChartStyle.TITANIUM, true, 100))
        assertEquals(ThemePresetChoice.Classic, ThemePresetChoice.matching("whoopBlue", ChartStyle.CLASSIC, true, 100))
    }

    @Test fun appleHealthMatchesWhateverTheChartColoursAre() {
        assertEquals(ThemePresetChoice.Health, ThemePresetChoice.matching("systemBlue", ChartStyle.CLASSIC, false, 100))
    }
}
