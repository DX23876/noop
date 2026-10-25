package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * MoodStore contract tests — the cross-platform Mind-lane storage contract:
 * source id "noop-mood", key "mood", value 1.0–5.0, ONE row per local day,
 * overwrite on edit. Runs against an in-memory stand-in for the metricSeries
 * table that reproduces its PK-(deviceId, day, key) @Upsert semantics exactly,
 * so no Room/Robolectric is needed.
 */
class MoodStoreTest {

    /** In-memory metricSeries: upsert overwrites on the (deviceId, day, key) natural key,
     *  query filters by deviceId+key+inclusive day range (lexicographic, like SQLite). */
    private class FakeSeries {
        val rows = LinkedHashMap<Triple<String, String, String>, MetricSeriesRow>()

        fun upsert(newRows: List<MetricSeriesRow>) {
            for (r in newRows) rows[Triple(r.deviceId, r.day, r.key)] = r
        }

        fun query(deviceId: String, key: String, from: String, to: String): List<MetricSeriesRow> =
            rows.values
                .filter { it.deviceId == deviceId && it.key == key && it.day >= from && it.day <= to }
                .sortedBy { it.day }
    }

    private fun storeOf(fake: FakeSeries) = MoodStore(
        { rows -> fake.upsert(rows) },
        { deviceId, key, from, to -> fake.query(deviceId, key, from, to) },
    )

    // MARK: - Store

    @Test
    fun storesUnderMoodSourceAndKey() = runBlocking {
        val fake = FakeSeries()
        val store = storeOf(fake)

        store.setMood("2026-06-12", 4.0)

        assertEquals(1, fake.rows.size)
        val row = fake.rows.values.single()
        assertEquals("noop-mood", row.deviceId)
        assertEquals("mood", row.key)
        assertEquals("2026-06-12", row.day)
        assertEquals(4.0, row.value, 0.0)
        // Read-back through the store API agrees.
        assertEquals(4.0, store.mood("2026-06-12")!!, 0.0)
    }

    @Test
    fun clampsValueToScale() = runBlocking {
        val fake = FakeSeries()
        val store = storeOf(fake)

        store.setMood("2026-06-12", 0.0)
        assertEquals(1.0, store.mood("2026-06-12")!!, 0.0)

        store.setMood("2026-06-12", 9.9)
        assertEquals(5.0, store.mood("2026-06-12")!!, 0.0)
    }

    // MARK: - Overwrite (one per local day)

    @Test
    fun overwritesSameDayInsteadOfDuplicating() = runBlocking {
        val fake = FakeSeries()
        val store = storeOf(fake)

        store.setMood("2026-06-12", 2.0)
        store.setMood("2026-06-12", 5.0)

        // Still exactly one row for the day — the edit overwrote in place.
        assertEquals(1, fake.rows.size)
        assertEquals(5.0, store.mood("2026-06-12")!!, 0.0)
        assertEquals(listOf("2026-06-12" to 5.0), store.moodSeries())
    }

    // MARK: - Read-back (day-keyed)

    @Test
    fun readBackIsDayKeyed() = runBlocking {
        val fake = FakeSeries()
        val store = storeOf(fake)

        store.setMood("2026-06-10", 3.0)
        store.setMood("2026-06-12", 5.0)
        store.setMood("2026-06-11", 1.0)

        // Per-day lookups hit exactly their own day.
        assertEquals(3.0, store.mood("2026-06-10")!!, 0.0)
        assertEquals(1.0, store.mood("2026-06-11")!!, 0.0)
        assertEquals(5.0, store.mood("2026-06-12")!!, 0.0)
        assertNull(store.mood("2026-06-09"))

        // Full series comes back oldest-first, one pair per day.
        assertEquals(
            listOf("2026-06-10" to 3.0, "2026-06-11" to 1.0, "2026-06-12" to 5.0),
            store.moodSeries(),
        )
        // Inclusive range filtering.
        assertEquals(
            listOf("2026-06-10" to 3.0, "2026-06-11" to 1.0),
            store.moodSeries(from = "2026-06-10", to = "2026-06-11"),
        )
    }

    @Test
    fun isolatedFromOtherSources() = runBlocking {
        val fake = FakeSeries()
        val store = storeOf(fake)

        // A same-day, same-key row from another source (e.g. an Apple Health export)
        // must never bleed into — or be clobbered by — native mood reads/writes.
        fake.upsert(listOf(MetricSeriesRow("apple-health", "2026-06-12", "mood", 2.0)))
        store.setMood("2026-06-12", 4.0)

        assertEquals(4.0, store.mood("2026-06-12")!!, 0.0)
        assertEquals(listOf("2026-06-12" to 4.0), store.moodSeries())
        // The foreign row survives untouched under its own source id.
        assertEquals(
            2.0,
            fake.rows[Triple("apple-health", "2026-06-12", "mood")]!!.value,
            0.0,
        )
        assertEquals(2, fake.rows.size)
    }

    // MARK: - Day key

    @Test
    fun todayKeyIsLocalIsoDay() {
        assertEquals("2026-06-12", MoodStore.todayKey(java.time.LocalDate.of(2026, 6, 12)))
    }
}
