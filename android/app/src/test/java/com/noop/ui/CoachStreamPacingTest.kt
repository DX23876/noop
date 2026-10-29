package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** A poll's new words are laid down one by one: each step ends after a word and its spaces. */
class CoachStreamPacingTest {
    @Test fun wordsAfterTheShownTextEndOneByOne() {
        val text = "Charge is fine today"
        assertEquals(listOf(7, 10, 15, 20), CoachViewModel.wordEnds(text, 0))
        assertEquals(listOf(15, 20), CoachViewModel.wordEnds(text, 9))
    }

    @Test fun nothingNewMeansNoSteps() {
        assertEquals(emptyList<Int>(), CoachViewModel.wordEnds("Done", 4))
    }
}
