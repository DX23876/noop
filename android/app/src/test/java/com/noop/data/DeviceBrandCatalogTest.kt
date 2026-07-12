package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure brand catalog: recognition, ordering, and the byte-parity facts (sourceKind / idPrefix /
 * capability / tier). Faithful twin of the Swift DeviceBrandCatalogTests — the SAME cases must hold so the
 * two platforms recognise a device identically.
 */
class DeviceBrandCatalogTest {

    @Test
    fun recognisesEachBrandFromAdvertisedName() {
        val cases = listOf(
            "Amazfit Helio Ring" to "Amazfit",
            "Zepp E" to "Amazfit",
            "Mi Smart Band 8" to "Mi Band",
            "Xiaomi Band 9" to "Mi Band",
            "Garmin Forerunner 265" to "Garmin",
            "fēnix 7" to "Garmin",            // diacritic-folded to "fenix"
            "HRM-Pro" to "Garmin",
            "Oura Ring" to "Oura",
            "Polar H10" to "Polar",
            "Wahoo TICKR" to "Wahoo",
            "COOSPO HW9" to "Coospo",
            "Scosche Rhythm+" to "Scosche",
            "Magene H64" to "Magene",
        )
        for ((name, expected) in cases) {
            assertEquals(name, expected, DeviceBrandCatalog.specForAdvertisedName(name)?.brand)
        }
    }

    @Test
    fun unknownNameIsNull() {
        assertNull(DeviceBrandCatalog.specForAdvertisedName("Acme HR 3000"))
        assertNull(DeviceBrandCatalog.specForAdvertisedName(""))
    }

    /** Mi Band (a Huami sub-brand) must win over the broader Amazfit family. */
    @Test
    fun miBandWinsOverAmazfit() {
        assertEquals("Mi Band", DeviceBrandCatalog.specForAdvertisedName("Mi Band")?.brand)
        assertEquals("Mi Band", DeviceBrandCatalog.specForAdvertisedName("Smart Band 10")?.brand)
    }

    @Test
    fun routingAndTierFacts() {
        fun spec(brand: String): DeviceBrandSpec =
            requireNotNull(DeviceBrandCatalog.specForBrand(brand)) { "missing catalog row for $brand" }

        assertEquals(SourceKind.huami, spec("Amazfit").sourceKind)
        assertEquals(SourceKind.huami, spec("Mi Band").sourceKind)
        assertEquals(SourceKind.oura, spec("Oura").sourceKind)
        assertEquals(SourceKind.liveBLE, spec("Garmin").sourceKind)
        assertEquals(SourceKind.liveBLE, spec("Polar").sourceKind)

        assertEquals("huami", spec("Amazfit").idPrefix)
        assertEquals("oura", spec("Oura").idPrefix)
        assertEquals("garmin", spec("Garmin").idPrefix)
        assertEquals("strap", spec("Polar").idPrefix)

        assertFalse(spec("Oura").canStreamLiveHR)
        assertTrue(spec("Amazfit").canStreamLiveHR)
        assertTrue(spec("Garmin").canStreamLiveHR)
        assertTrue(spec("Polar").canStreamLiveHR)

        for (b in listOf("Amazfit", "Mi Band", "Garmin", "Oura")) assertTrue(b, spec(b).isExperimentalTier)
        for (b in listOf("Polar", "Wahoo", "Coospo", "Scosche", "Magene")) assertFalse(b, spec(b).isExperimentalTier)
    }

    @Test
    fun brandStringsUnique() {
        val brands = DeviceBrandCatalog.all.map { it.brand }
        assertEquals(brands.size, brands.toSet().size)
    }
}
