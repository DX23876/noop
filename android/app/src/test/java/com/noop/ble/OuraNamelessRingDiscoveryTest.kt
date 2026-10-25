package com.noop.ble

import com.noop.data.DeviceBrandCatalog
import com.noop.oura.OuraRingGen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins why the Oura scan callback must NOT gate discovery on the advertised name (open_oura issue #13).
 *
 * The measured bug: `OuraLiveSource.scanCallback` dropped every result whose name did not recognise as
 * Oura (`ExperimentalBrand.recognise(name) != OURA`). A BONDED ring often stops advertising a local name,
 * and Android's `device.name` bond-cache fallback is empty when the bond lives elsewhere, so `name` is
 * `""` — and no brand token is a substring of `""`, so the gate rejected the one ring the user most wanted
 * to reconnect to. It still advertised SERVICE_UUID, so `startScan`'s ScanFilter had already accepted it.
 *
 * These assertions are the trap itself, not the fix: they hold both before and after. They exist so that
 * anyone reinstating a name-based drop sees, headlessly, that a blank name recognises as nothing. The fix
 * (no name gate in the callback; the ScanFilter is the only gate) is a live BLE discovery behaviour and
 * cannot be asserted here — it is validated on hardware. Apple has always behaved this way
 * (Strand/BLE/OuraLiveSource.swift), so this also closes a cross-platform divergence.
 *
 * What CAN be asserted headlessly is how the nameless ring is then LABELLED, which is the last test here.
 * #1783 reports that label arriving blank in the wizard on both platforms; it does not, because
 * `ouraAdvertisedLabel` substitutes a fallback at the single `DiscoveredRing` construction site on each
 * platform. That test pins the rule so the guard cannot be dropped as redundant later.
 */
class OuraNamelessRingDiscoveryTest {

    @Test
    fun `a blank advertised name recognises as no brand - the whole bug`() {
        assertNull("no brand token is a substring of \"\"",
                   DeviceBrandCatalog.specForAdvertisedName(""))
        assertNull("so the old callback gate dropped a nameless bonded ring",
                   ExperimentalBrand.recognise(""))
    }

    @Test
    fun `a named ring recognises fine, so the bug was specific to the nameless case`() {
        assertEquals(ExperimentalBrand.OURA, ExperimentalBrand.recognise("Oura Ring 4"))
        assertEquals(ExperimentalBrand.OURA, ExperimentalBrand.recognise("oura 2h3b2405003655"))
    }

    /**
     * The label rule itself, pinned against the Swift twin's OWN output.
     *
     * Every expected value below is stdout from `ouraAdvertisedLabel` in
     * `Strand/BLE/OuraLiveSource.swift`, compiled standalone (`swiftc -O twin.swift main.swift`) over this
     * exact case list and pasted verbatim - not read off the Kotlin implementation, and not eyeballed.
     * That is what caught the divergence this test exists for: the first draft of the Kotlin helper was
     * `advertisedName.trim().ifEmpty { fallback }`, which returns the TRIMMED name, while Swift returns
     * the original. The `" Oura Ring 4 "` case is the one that separates them.
     *
     * Whitespace, not emptiness, is the boundary - a ring advertising `" "` used to list as "Oura" here
     * and blank on Apple. This guards only the ASCII whitespace a BLE local name can realistically carry;
     * the two stdlib definitions part on exotic Unicode spaces (U+00A0), which is documented at the
     * helper rather than asserted here.
     */
    @Test
    fun `the label rule matches the Swift twin byte for byte`() {
        assertEquals("Oura", ouraAdvertisedLabel("", "Oura"))
        assertEquals("Oura ring", ouraAdvertisedLabel("", "Oura ring"))
        assertEquals("Oura", ouraAdvertisedLabel(" ", "Oura"))
        assertEquals("Oura", ouraAdvertisedLabel("   ", "Oura"))
        assertEquals("Oura", ouraAdvertisedLabel("\t", "Oura"))
        assertEquals("Oura", ouraAdvertisedLabel("\n", "Oura"))
        assertEquals("Oura", ouraAdvertisedLabel(" \t\n ", "Oura"))
        assertEquals("Oura Ring 4", ouraAdvertisedLabel("Oura Ring 4", "Oura"))
        assertEquals("oura 2h3b2405003655", ouraAdvertisedLabel("oura 2h3b2405003655", "Oura"))
        assertEquals(" Oura Ring 4 ", ouraAdvertisedLabel(" Oura Ring 4 ", "Oura"))
        assertEquals("O", ouraAdvertisedLabel("O", "Oura"))
        assertEquals("Oura ring", ouraAdvertisedLabel("Oura ring", "Oura"))
    }

    @Test
    fun `a nameless ring also has no detectable generation, so the wizard must default`() {
        // `AddDeviceWizard` reads `ring.detectedGen ?: OuraRingGen.GEN3` and labels it "Oura ring";
        // the Apple twin does the same. Listing a nameless ring therefore needs no further wiring.
        assertNull(OuraRingGen.recognise(""))
    }
}
