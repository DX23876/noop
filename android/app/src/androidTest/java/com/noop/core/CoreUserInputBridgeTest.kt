package com.noop.core

import android.content.ContextWrapper
import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.noop.data.JournalEntry
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Exercises the real Room snapshot, repository forwarding and packaged Swift store in one isolated session. */
@RunWith(AndroidJUnit4::class)
class CoreUserInputBridgeTest {
    @Test
    fun inputsMoveOnceThenAllEditsUseTheCore() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val dir = File(context.cacheDir, "input-bridge-${UUID.randomUUID()}").apply { mkdirs() }
        val isolated = object : ContextWrapper(context) { override fun getFilesDir(): File = dir }
        val room = Room.inMemoryDatabaseBuilder(context, WhoopDatabase::class.java).build()
        try {
            assertFalse("Use a fresh instrumentation process, without an Activity", CoreShadow.running)
            CoreShadow.ensureStarted(isolated, "input-bridge")
            assertTrue(CoreShadow.running)
            val day = "2099-01-02"
            val question = " Caffeine\n"
            val original = JournalEntry("noop-journal", day, question, true, "Original", 50.0)
            room.whoopDao().upsertJournal(listOf(original))
            room.whoopDao().upsertMetricSeries(listOf(
                MetricSeriesRow("hydration", day, "hydration", 200.0),
                MetricSeriesRow("hydration", day, "hydrationImported", 500.0)))
            val repo = WhoopRepository(room, CoreUserInputs(isolated))
            assertEquals(listOf(original), repo.journal("noop-journal", day, day))
            val changed = original.copy(answeredYes = false, notes = null, numericValue = 0.0)
            repo.upsertJournal(listOf(changed))
            assertEquals(listOf(changed), repo.journal("noop-journal", day, day))
            assertEquals("Room is a retained migration source, never a second writer",
                listOf(original), room.whoopDao().journal("noop-journal", day, day))
            repo.upsertMetricSeries(listOf(MetricSeriesRow("hydration", day, "hydrationImported", 0.0)))
            assertEquals(200.0, repo.metricSeries("hydration", "hydration", day, day).single().value, 0.0)
            assertEquals(0.0, repo.metricSeries("hydration", "hydrationImported", day, day).single().value, 0.0)
            assertEquals(500.0, room.whoopDao().metricSeries("hydration", "hydrationImported", day, day).single().value, 0.0)
            repo.deleteJournalEntry("noop-journal", day, question)
            // A second repository must consult the database marker, not replay the old row after its deletion.
            val reopened = WhoopRepository(room, CoreUserInputs(isolated))
            assertTrue(reopened.journal("noop-journal", day, day).isEmpty())
            assertEquals(1, reopened.metricSeriesKeyCount("hydration", "hydrationImported"))
            assertEquals(listOf("hydration", "hydrationImported"), reopened.metricKeys("hydration"))
        } finally {
            room.close()
            dir.deleteRecursively()
        }
    }
}
