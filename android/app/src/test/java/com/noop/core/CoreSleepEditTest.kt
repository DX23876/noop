package com.noop.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the Sleep screen is told about a correction (`CoreSleepEdit`).
 *
 * The whole point of this answer shape is that nothing can be read as "it worked" by accident. Before it
 * existed, a correction that reached no row looked exactly like one that did: the group came back empty,
 * the write was wrapped in a catch, the dialog closed, and the strap log said nothing. A tester lost every
 * correction he made to a night NOOP had computed itself and could not tell anyone why (2026-11-21).
 */
class CoreSleepEditTest {

    @Test fun aSavedChangeCarriesItsRetiredRowsAndItsUndoToken() {
        val answer = CoreSleepEdit.parse(
            """{"ok":true,"outcome":"saved","edited":2,"rescore":true,"undoToken":"abc",
               "wakeDays":["2026-11-20"],
               "retired":[{"deviceId":"my-whoop-noop","startTs":100,"endTs":200,"writesTombstone":true}]}""")
        assertTrue(answer.ok)
        assertEquals(2, answer.edited)
        assertEquals("abc", answer.undoToken)
        assertEquals(listOf("2026-11-20"), answer.wakeDays)
        assertTrue(answer.rescore)
        assertEquals(CoreSleepEdit.Retired("my-whoop-noop", 100, 200, true), answer.retired.single())
    }

    /**
     * A partial deletion counts as something having happened: the rows that went are gone, so the undo
     * must work and the day must be scored again. The screen says the rest is still there on top of that.
     */
    @Test fun aPartialDeletionIsStillAChange() {
        val answer = CoreSleepEdit.parse(
            """{"ok":true,"outcome":"partial","edited":0,"undoToken":"t",
               "retired":[{"deviceId":"my-whoop","startTs":1,"endTs":2,"writesTombstone":false}]}""")
        assertEquals(CoreSleepEdit.Outcome.PARTIAL, answer.outcome)
        assertTrue("what was removed is gone either way", answer.ok)
        assertEquals("t", answer.undoToken)
    }

    @Test fun everyRefusalKeepsItsOwnName() {
        for (outcome in listOf(CoreSleepEdit.Outcome.NO_BLOCKS, CoreSleepEdit.Outcome.INVALID_WINDOW,
                               CoreSleepEdit.Outcome.NO_OVERLAP, CoreSleepEdit.Outcome.OWNER_UNRESOLVED,
                               CoreSleepEdit.Outcome.WRITE_FAILED, CoreSleepEdit.Outcome.NOT_FOUND)) {
            val answer = CoreSleepEdit.parse("""{"ok":false,"outcome":"${outcome.raw}"}""")
            assertEquals(outcome, answer.outcome)
            assertFalse("a refusal must never read as done", answer.ok)
        }
    }

    /**
     * An outcome this build does not know is NOT success. A newer core naming a refusal we have no word
     * for must still stop the screen from saying the night was changed.
     */
    @Test fun anUnknownOutcomeIsNotSuccess() {
        val answer = CoreSleepEdit.parse("""{"ok":false,"outcome":"somethingNewer"}""")
        assertFalse(answer.ok)
        assertEquals(CoreSleepEdit.Outcome.WRITE_FAILED, answer.outcome)
    }

    @Test fun aCoreThatAnsweredWithAnErrorIsNotADoneChange() {
        val answer = CoreSleepEdit.parse("""{"error":"noStore"}""")
        assertEquals(CoreSleepEdit.Outcome.NO_CORE, answer.outcome)
        assertFalse(answer.ok)
    }

    @Test fun nothingRetiredMeansNoUndoToken() {
        val answer = CoreSleepEdit.parse("""{"ok":true,"outcome":"saved","edited":1}""")
        assertTrue(answer.ok)
        assertNull(answer.undoToken)
        assertTrue(answer.retired.isEmpty())
    }
}
