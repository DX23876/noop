package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the WHOOP 4.0 reboot-probe candidate table (#235). These values are a byte-identical
 * cross-platform contract: the [RebootProbeVariant.logTag] (and each candidate's command / payload)
 * MUST match the Swift `RebootProbeVariant` (Strand/BLE/Commands.swift), so a captured 4.0 strap log
 * reads the same on either platform. Change one side → change the other, or the log stops correlating.
 */
class RebootProbeVariantTest {

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    @Test fun tableOrderAndTagsPinned() {
        assertEquals(3, RebootProbeVariant.entries.size)
        assertEquals(
            listOf("A/reboot29-empty", "B/powercycle32-empty", "C/reboot29-payload01"),
            RebootProbeVariant.entries.map { it.logTag },
        )
        assertEquals(
            listOf(
                "A · REBOOT_STRAP(29) empty",
                "B · POWER_CYCLE(32) empty",
                "C · REBOOT_STRAP(29) payload=01",
            ),
            RebootProbeVariant.entries.map { it.menuLabel },
        )
    }

    @Test fun candidateA_reboot29Empty() {
        val a = RebootProbeVariant.REBOOT_29_EMPTY
        assertEquals(CommandNumber.REBOOT_STRAP, a.command)
        assertEquals("", a.payload.hex())
    }

    @Test fun candidateB_powerCycle32Empty() {
        val b = RebootProbeVariant.POWER_CYCLE_32_EMPTY
        assertEquals(CommandNumber.POWER_CYCLE_STRAP, b.command)
        assertEquals("", b.payload.hex())
    }

    @Test fun candidateC_reboot29Payload1() {
        val c = RebootProbeVariant.REBOOT_29_PAYLOAD1
        assertEquals(CommandNumber.REBOOT_STRAP, c.command)
        assertEquals("01", c.payload.hex())
    }

    /** The two restart candidates carry the real, distinct wire opcodes (29 reboot, 32 power-cycle) — a
     *  guard against a candidate silently pointing at the wrong CommandNumber. */
    @Test fun candidatesUseExpectedWireOpcodes() {
        assertEquals(29, RebootProbeVariant.REBOOT_29_EMPTY.command.rawValue)
        assertEquals(32, RebootProbeVariant.POWER_CYCLE_32_EMPTY.command.rawValue)
        assertEquals(29, RebootProbeVariant.REBOOT_29_PAYLOAD1.command.rawValue)
    }
}
