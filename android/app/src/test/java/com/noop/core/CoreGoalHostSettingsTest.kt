package com.noop.core

import com.noop.ui.JournalCatalogItem
import com.noop.ui.JournalGroup
import com.noop.ui.JournalKind
import org.junit.Assert.assertEquals
import org.junit.Test

/** The catalog Android hands the goal reader must be Swift's `JournalCatalogItem` coding (`CoreGoalHabitsTests`). */
class CoreGoalHostSettingsTest {
    @Test fun theCatalogWireUsesTheSwiftCoding() {
        val wire = journalCatalogWire(listOf(
            JournalCatalogItem("Alcohol", "Drinks", JournalKind.Numeric("units"), JournalGroup.Lifestyle, 0, false, false),
            JournalCatalogItem("Stretching", null, JournalKind.Bool, JournalGroup.Other, 1, true, true),
        ))
        val alcohol = wire.getJSONObject(0)
        assertEquals("Alcohol", alcohol.getString("canonical"))
        assertEquals("Drinks", alcohol.getString("displayName"))
        assertEquals("units", alcohol.getJSONObject("kind").getJSONObject("numeric").getString("unitLabel"))
        assertEquals("lifestyle", alcohol.getString("group"))
        assertEquals(0, alcohol.getJSONArray("aliases").length())
        val stretching = wire.getJSONObject(1)
        assertEquals(0, stretching.getJSONObject("kind").getJSONObject("bool").length())
        assertEquals("other", stretching.getString("group"))
        assertEquals(false, stretching.has("displayName"))
        assertEquals(true, stretching.getBoolean("hidden"))
        assertEquals(true, stretching.getBoolean("custom"))
    }
}
