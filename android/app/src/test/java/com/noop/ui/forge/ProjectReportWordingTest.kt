package com.noop.ui.forge

import com.noop.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * A report that did not go out says WHICH of the four reasons it was. Before this, every cause reached
 * the screen as "that did not go out, try again later": a switch the wearer threw themselves, a rate
 * limit that waiting fixes, a service that answered no and a connection that is not there, all worded
 * the same. A tester could not act on it and nobody could diagnose it from the outside.
 *
 * The reason is decided once, in the shared core (`ProjectService.failure`), and arrives over the
 * bridge as a name. This is only the mapping from that name to words, and the twin of
 * `ProjectReportWording` on Apple.
 */
class ProjectReportWordingTest {
    /// Every reason the core can name has a sentence of its own, and no two share one.
    @Test
    fun eachReasonHasItsOwnSentence() {
        val byReason = listOf("notSending", "tooMany", "refused", "unreachable")
            .associateWith { ProjectReportWording.sentence(it) }
        assertEquals(4, byReason.values.toSet().size)
        assertEquals(R.string.project_report_failed_not_sending, byReason["notSending"])
        assertEquals(R.string.project_report_failed_too_many, byReason["tooMany"])
        assertEquals(R.string.project_report_failed_refused, byReason["refused"])
        assertEquals(R.string.project_report_failed_unreachable, byReason["unreachable"])
    }

    /// A name this screen does not know reads as silence, never as one of the other three. A core that
    /// learns a fifth reason before this app does must not print something that did not happen: of the
    /// four, "nothing answered" is the only one that claims nothing about the far side.
    @Test
    fun anUnknownReasonReadsAsSilence() {
        for (name in listOf("", "boom", "notsending", "TOO_MANY", "429")) {
            assertEquals(R.string.project_report_failed_unreachable,
                         ProjectReportWording.sentence(name))
        }
        assertNotEquals(R.string.project_report_failed_not_sending,
                        ProjectReportWording.sentence("notsending"))
    }
}
