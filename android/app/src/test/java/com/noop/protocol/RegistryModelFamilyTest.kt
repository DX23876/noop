package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Registry model-label → [DeviceFamily] resolution (#171). Mirrors the macOS `RegistryModelFamilyTests`.
 *
 * The device registry holds several historical spellings for the same hardware — the Add-Device
 * wizard's bare "4.0" / "5.0 MG", the full picker labels ("WHOOP 4.0" / "WHOOP 5.0 / MG"), and the
 * legacy seeded "my-whoop" row's bare "WHOOP". Call sites that compared ONE spelling silently missed
 * the others (issue #171: wizard-paired 4.0 straps decoded on the 5/MG /100 scale, ~8 °C skin temps
 * in the Deep Timeline). These tests pin the full label contract so a new spelling — or a regression
 * back to a single-spelling comparison — fails loudly.
 */
class RegistryModelFamilyTest {

    // ── WHOOP 4.0 — every stored spelling must positively identify (the #171 fix) ──

    @Test
    fun wizardBare40LabelResolvesToWhoop4() {
        assertEquals(DeviceFamily.WHOOP4, DeviceFamily.forRegistryModel("4.0"))
    }

    @Test
    fun fullPicker40LabelResolvesToWhoop4() {
        assertEquals(DeviceFamily.WHOOP4, DeviceFamily.forRegistryModel("WHOOP 4.0"))
    }

    // ── WHOOP 5/MG — both spellings keep the /100 path ──────────────────────

    @Test
    fun wizard5MgLabelResolvesToWhoop5() {
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("5.0 MG"))
        // "WHOOP 5.0 MG" is a spelling no writer produces today (the picker writes
        // "WHOOP 5.0 / MG"); it lands on the safe WHOOP5 default, which happens to be correct.
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("WHOOP 5.0 MG"))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("WHOOP 5.0 / MG"))
    }

    // ── Legacy + unknowns — the prior WHOOP5 fallback, unchanged ────────────

    @Test
    fun legacySeededWhoopLabelKeepsWhoop5Fallback() {
        // The seeded "my-whoop" row predates the wizard and was written identically for 4.0 and
        // 5/MG installs, so "WHOOP" carries no family information; it keeps the prior fallback.
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("WHOOP"))
    }

    @Test
    fun nullEmptyAndGarbageFallBackToWhoop5() {
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel(null))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel(""))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("Oura Ring Gen3"))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("garmin-hrm"))
    }
}
