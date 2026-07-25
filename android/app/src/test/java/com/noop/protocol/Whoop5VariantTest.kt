package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors WhoopProtocolTests/Whoop5VariantTests.swift — same fixtures, same expected outputs, so the
 * twin resolvers cannot drift.
 */
class Whoop5VariantTest {

    @Test fun serialPrefixIdentifiesMg() {
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("5AM12345678"))
        assertTrue(Whoop5Variant.from("5AM12345678").isMG)
    }

    @Test fun serialPrefixIdentifiesFiveZero() {
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from("5AG12345678"))
        assertFalse(Whoop5Variant.from("5AG12345678").isMG)
    }

    @Test fun hardwareRevisionIsDeviceAttestedFiveZero() {
        // The observed 5.0 hardware id, with no serial available at all.
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from(null, "WG50_r52"))
    }

    @Test fun advertisedNamePrefixTolerated() {
        // Callers may pass the advertised name instead of the DIS serial.
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("WHOOP 5AM12345678"))
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from("  whoop 5ag12345678  "))
    }

    @Test fun contradictionYieldsUnknownRatherThanAGuess() {
        // Only the 5.0 hardware string is attested today; a contradiction means our model is
        // incomplete, so refuse to pick a winner (#716: a mis-stamped model is worse than none).
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("5AM12345678", "WG50_r52"))
    }

    @Test fun agreeingSignalsResolve() {
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from("5AG12345678", "WG50_r52"))
    }

    @Test fun unattestedInputsAreUnknownNeverInferred() {
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(null))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(""))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("WHOOP"))
        // A stray digit in the name must NOT imply a generation (#772 — the bug that read a
        // serial's "5" as Gen5 on a Gen3 ring; same failure mode, different product).
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("WHOOP 4.0"))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("5XX99999999"))
        // An MG hardware-revision string is not yet attested, so it must not resolve by itself.
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(null, "WGMG_r01"))
    }

    @Test fun labels() {
        assertEquals("MG", Whoop5Variant.MG.label)
        assertEquals("5.0", Whoop5Variant.FIVE_ZERO.label)
        assertEquals("—", Whoop5Variant.UNKNOWN.label)
    }
}
