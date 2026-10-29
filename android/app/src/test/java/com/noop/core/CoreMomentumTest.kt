package com.noop.core

import org.junit.Assert.*
import org.junit.Test

/** A broken bridge response must remain a read failure, rather than an honestly empty feed. */
class CoreMomentumTest {
    @Test fun malformedAndMissingFeedsAreFailures() {
        listOf("null", "{", "{}", "{\"error\":\"store\"}", "{\"messages\":[{}]}").forEach {
            assertNull(it, CoreMomentum.parse(it))
        }
        assertEquals(emptyList<CoreMomentum.Message>(), CoreMomentum.parse("{\"messages\":[]}"))
    }

    @Test fun messageFieldsKeepTheirTypesAndOptionalAbsence() {
        val message = CoreMomentum.parse("""{"messages":[{"kind":"weeklyGoal","tone":"positive",
            "headline":"error","detail":"One more session","progress":0.5,
            "actionTitle":"Open goals","destination":"goalJourney"}]}""")!!.single()
        assertEquals("error", message.headline)
        assertEquals(0.5, message.progress!!, 0.0)
        assertEquals("goalJourney", message.destination)
        assertNull(message.deltaText)
        assertNull(message.actionLine)
    }
}
