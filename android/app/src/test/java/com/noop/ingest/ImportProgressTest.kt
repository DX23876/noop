package com.noop.ingest

import android.content.Context
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The one fact three readers draw: the import page, the home screen banner and the lock-screen
 * notification.
 *
 * What makes it worth a test is the thing that is NOT here: none of the three works anything out. A
 * second reader that counted its own records, or decided for itself whether an import was running, is
 * exactly the shape that put "banked" over offered counts in the strap log and made a tester's history
 * read as lost. So the cases below pin the state machine instead of any one screen.
 *
 * Robolectric for the Context alone. There is no application object under it, which is itself worth
 * covering: the progress must still work when the strap log cannot be reached, since a diagnostic that
 * can take the app down with it is worse than no diagnostic.
 */
@RunWith(RobolectricTestRunner::class)
class ImportProgressTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    @After
    fun clearProgress() {
        ImportProgress.end(context)
    }

    @Test
    fun `nothing runs until an importer says it started`() {
        assertNull(ImportProgress.state.value)
        assertFalse(ImportProgress.running)
    }

    @Test
    fun `a read without a running import cannot invent one`() {
        // The counter is handed every page of every read, including the ones outside an import (the
        // Today steps top-up reads Health Connect on its own). One of those must not raise a banner.
        ImportProgress.read(5_000)
        assertNull(ImportProgress.state.value)
    }

    @Test
    fun `a step without a running import cannot leave one on screen`() {
        ImportProgress.step(context, ImportProgress.Step.SAVING)
        assertNull(ImportProgress.state.value)
    }

    @Test
    fun `the steps and the records accumulate into one state`() {
        ImportProgress.begin(context, "health-connect")
        assertEquals(ImportProgress.Step.READING, ImportProgress.state.value?.step)
        assertEquals(0, ImportProgress.state.value?.records)

        ImportProgress.step(context, ImportProgress.Step.READING, "HeartRateRecord")
        ImportProgress.read(1_200)
        ImportProgress.read(800)
        assertEquals("HeartRateRecord", ImportProgress.state.value?.detail)
        assertEquals(2_000, ImportProgress.state.value?.records)

        // A step keeps what has been read: the count is the import's, not the step's, and a reader
        // watching it must never see it fall back to zero halfway through.
        ImportProgress.step(context, ImportProgress.Step.SAVING)
        assertEquals(ImportProgress.Step.SAVING, ImportProgress.state.value?.step)
        assertEquals(2_000, ImportProgress.state.value?.records)
        assertTrue(ImportProgress.running)
    }

    /**
     * The label's own halves. Asserted here rather than through `stepLabel`, because this module does not
     * build its resources for unit tests, so a `getString` in one throws rather than failing on what it
     * returned. What is left to get wrong is the joining, and that is what this covers: the importer's
     * key cannot reach a wearer, because the function that builds the sentence is never given it.
     */
    @Test
    fun `the label joins the step and the count, and nothing else`() {
        assertEquals("Reading data", ImportProgress.joinedLabel("Reading data", null))
        assertEquals("Reading data", ImportProgress.joinedLabel("Reading data", ""))
        assertEquals("Reading data · 42 entries", ImportProgress.joinedLabel("Reading data", "42 entries"))
    }

    @Test
    fun `ending clears it, and ending twice is harmless`() {
        ImportProgress.begin(context, "health-connect")
        ImportProgress.end(context)
        assertNull(ImportProgress.state.value)
        ImportProgress.end(context)
        assertNull(ImportProgress.state.value)
    }
}
