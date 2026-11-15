package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [GenericHrProfileGate] — the send allowlist for `TOGGLE_GENERIC_HR_PROFILE(14)`.
 *
 * The point of each test is the REFUSAL: the predicate the real 5/MG send path consults is proved here to
 * reject every opcode and body that is not this one command's own, so a test about the predicate is a test
 * about the wire path rather than about a parallel copy of the rule. Twin of the Swift
 * `GenericHrProfileGateTests`.
 */
class GenericHrProfileGateTest {

    @Test
    fun `admits only the two well-formed bodies under the opt-in`() {
        for (on in listOf(true, false)) {
            assertTrue(
                GenericHrProfileGate.admitsSend(
                    GenericHrProfileGate.TOGGLE_GENERIC_HR_PROFILE_CMD,
                    GenericHrProfileGate.body(on),
                    broadcastHrOptIn = true,
                ),
            )
        }
    }

    @Test
    fun `without the opt-in the on write is refused and the off write is not`() {
        // The asymmetry IS the fix. The opt-in is bound straight to the Settings switch, so it is already
        // false by the time setBroadcastHr(false) runs: gating the off direction on it refuses the one
        // write that stops the strap serving its heart rate, which is the dead undo path #1061 and #174
        // each shipped once already.
        assertFalse(
            "the ON write needs the opt-in",
            GenericHrProfileGate.admitsSend(
                GenericHrProfileGate.TOGGLE_GENERIC_HR_PROFILE_CMD,
                GenericHrProfileGate.body(true),
                broadcastHrOptIn = false,
            ),
        )
        assertTrue(
            "the OFF write is the undo and must never need the opt-in",
            GenericHrProfileGate.admitsSend(
                GenericHrProfileGate.TOGGLE_GENERIC_HR_PROFILE_CMD,
                GenericHrProfileGate.body(false),
                broadcastHrOptIn = false,
            ),
        )
    }

    @Test
    fun `a replayed event is not the current state`() {
        // A strap banks these events, so an offload hands over an old one. Reporting that as the present
        // state prints the opposite of the truth for a service switched since.
        for (event in listOf(GenericHrProfileGate.ENABLED_EVENT, GenericHrProfileGate.DISABLED_EVENT)) {
            assertNull(GenericHrProfileGate.liveStateFromEvent(event, replayedOffload = true))
            assertEquals(
                GenericHrProfileGate.stateFromEvent(event),
                GenericHrProfileGate.liveStateFromEvent(event, replayedOffload = false),
            )
        }
    }

    @Test
    fun `refuses every other opcode including the device-config write`() {
        // 119 is the other route the same switch uses on a 5/MG. It keeps its own key-aware gate and must
        // never be reachable from this one, which is why it is named in the gate rather than merely absent.
        assertFalse(
            GenericHrProfileGate.admitsSend(
                GenericHrProfileGate.SET_DEVICE_CONFIG_VALUE_CMD,
                byteArrayOf(1),
                broadcastHrOptIn = true,
            ),
        )
        for (opcode in 0..255) {
            if (opcode == GenericHrProfileGate.TOGGLE_GENERIC_HR_PROFILE_CMD) continue
            assertFalse(
                "opcode $opcode must not ride this clause",
                GenericHrProfileGate.admitsSend(opcode, byteArrayOf(1), broadcastHrOptIn = true),
            )
        }
    }

    @Test
    fun `refuses a malformed body`() {
        // Exact-length matching is deliberate: a longer body is not a request this app formed, and "first
        // byte wins" would widen the gate to whatever a future caller happens to pass.
        val bad = listOf(
            byteArrayOf(),
            byteArrayOf(2),
            byteArrayOf(0xFF.toByte()),
            byteArrayOf(1, 0),
            byteArrayOf(0, 0),
            byteArrayOf(1, 1, 1),
        )
        for (payload in bad) {
            assertFalse(
                GenericHrProfileGate.admitsSend(
                    GenericHrProfileGate.TOGGLE_GENERIC_HR_PROFILE_CMD,
                    payload,
                    broadcastHrOptIn = true,
                ),
            )
            assertNull(GenericHrProfileGate.requestedState(payload))
        }
    }

    @Test
    fun `requested state reads back what body wrote`() {
        assertEquals(true, GenericHrProfileGate.requestedState(GenericHrProfileGate.body(true)))
        assertEquals(false, GenericHrProfileGate.requestedState(GenericHrProfileGate.body(false)))
    }

    @Test
    fun `state from event names only the two events`() {
        assertEquals(true, GenericHrProfileGate.stateFromEvent(GenericHrProfileGate.ENABLED_EVENT))
        assertEquals(false, GenericHrProfileGate.stateFromEvent(GenericHrProfileGate.DISABLED_EVENT))
        // The decoder appends the raw number to an event name, so the match is a prefix match.
        assertEquals(true, GenericHrProfileGate.stateFromEvent("${GenericHrProfileGate.ENABLED_EVENT}(24)"))
        assertEquals(false, GenericHrProfileGate.stateFromEvent("${GenericHrProfileGate.DISABLED_EVENT}(25)"))
        for (other in listOf("BLE_BONDED", "WRIST_ON", "BLE_REALTIME_HR_ON", "BATTERY_LEVEL", "")) {
            assertNull(GenericHrProfileGate.stateFromEvent(other))
        }
    }
}
