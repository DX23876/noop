package com.noop.core

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.noop.data.JournalEntry
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopDatabase
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/**
 * Fork (DX23876), Android without Room: the generated data access ([com.noop.data.CoreWhoopDao]) writes and reads
 * the packaged Swift core's store, in one isolated session.
 */
@RunWith(AndroidJUnit4::class)
class CoreDaoBridgeTest {
    @Test
    fun theDataAccessWritesAndReadsTheCoresStore() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val dir = File(context.cacheDir, "core-dao-${UUID.randomUUID()}").apply { mkdirs() }
        val isolated = object : ContextWrapper(context) { override fun getFilesDir(): File = dir }
        try {
            assertFalse("Use a fresh instrumentation process, without an Activity", CoreShadow.running)
            CoreShadow.ensureStarted(isolated, "core-dao")
            assertTrue(CoreShadow.running)
            val dao = WhoopDatabase.get(context).whoopDao()
            val day = "2099-01-02"
            val entry = JournalEntry("noop-journal", day, " Caffeine\n", true, "Original", 50.0)
            dao.upsertJournal(listOf(entry))
            assertEquals(listOf(entry), dao.journal("noop-journal", day, day))
            dao.upsertMetricSeries(listOf(MetricSeriesRow("hydration", day, "hydration", 200.0)))
            dao.upsertMetricSeries(listOf(MetricSeriesRow("hydration", day, "hydration", 250.0)))
            assertEquals(250.0, dao.metricSeries("hydration", "hydration", day, day).single().value, 0.0)
        } finally {
            dir.deleteRecursively()
        }
    }
}
