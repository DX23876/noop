package com.noop.data

import com.noop.protocol.StandardHrContact
import org.json.JSONException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class StandardHrMappingTest {
    @Test
    fun contactUsesSwiftParityEventShape() {
        assertEquals(
            EventEntry(
                ts = 1_750_000_000L,
                kind = "STANDARD_HR_CONTACT",
                payloadJSON = "{\"contact\":\"supported_not_detected\"}",
            ),
            StandardHrMapping.contactEvent(
                1_750_000_000L,
                StandardHrContact.SUPPORTED_NOT_DETECTED,
            ),
        )
    }

    @Test
    fun contactReadParsesPayloadJsonRegardlessOfKeyOrder() {
        val row = EventRow(
            deviceId = "whoop-5",
            ts = 1_750_000_001L,
            kind = StandardHrMapping.CONTACT_EVENT_KIND,
            payloadJSON = "{\"extra\":true,\"contact\":\"supported_detected\"}",
        )
        assertEquals(
            StandardHrContactSample(1_750_000_001L, StandardHrContact.SUPPORTED_DETECTED),
            StandardHrMapping.contactSample(row),
        )
    }

    @Test
    fun invalidPayloadJsonIsParseFailureNotAbsence() {
        val row = EventRow(
            deviceId = "whoop-5",
            ts = 1_750_000_001L,
            kind = StandardHrMapping.CONTACT_EVENT_KIND,
            payloadJSON = "{\"contact\":\"supported_detected\"}",
        )
        try {
            StandardHrMapping.contactSample(row.copy(payloadJSON = "not-json"))
            fail("expected parse failure")
        } catch (e: JSONException) {
            // parse failure must not collapse into "no contact event"
        }
        try {
            StandardHrMapping.contactSample(row.copy(payloadJSON = "{}"))
            fail("expected parse failure")
        } catch (e: JSONException) {
            // missing contact key is a parse failure, not legacy absence
        }
    }

    /**
     * Contact is a state, not a measurement. A ~1 Hz stream that recorded every reading wrote ~86,400
     * rows a day per device to say the same thing, for a read side that only ever needed the changes.
     *
     * Asserted over a SEQUENCE rather than on the predicate alone: the number that matters is how many
     * rows a run of readings produces, and a predicate test would pass just as happily if the caller
     * stopped consulting it.
     */
    @Test
    fun `a run of identical readings records one row, and each change records one more`() {
        val readings = List(600) { StandardHrContact.SUPPORTED_DETECTED } +
            List(300) { StandardHrContact.SUPPORTED_NOT_DETECTED } +
            List(600) { StandardHrContact.SUPPORTED_DETECTED }

        var previous: StandardHrContact? = null
        var recorded = 0
        for (c in readings) {
            if (StandardHrMapping.shouldRecordContact(previous, c)) { recorded++; previous = c }
        }
        // 1500 readings — a full session — become three rows: the opening state and two transitions.
        assertEquals(3, recorded)
    }

    @Test
    fun `the first reading always records, so a session never opens with an assumed state`() {
        assertTrue(StandardHrMapping.shouldRecordContact(null, StandardHrContact.UNSUPPORTED))
        assertTrue(StandardHrMapping.shouldRecordContact(null, StandardHrContact.SUPPORTED_DETECTED))
        // ...and an unchanged repeat does not.
        assertFalse(StandardHrMapping.shouldRecordContact(
            StandardHrContact.SUPPORTED_DETECTED, StandardHrContact.SUPPORTED_DETECTED))
    }
}
