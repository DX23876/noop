package com.noop.analytics

import com.noop.data.HrSample
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`): the Kotlin copies Android's screens
 * still run, checked against the Swift code iOS runs. `CoreParityOracleTests.swift` writes generated inputs with the
 * Swift answers to `core_parity/`; this runs the Kotlin copy over the same inputs. Every oracle on disk needs a
 * runner here, so a new one cannot be skipped.
 */
class CoreParityTest {
    private fun hr(a: JSONArray?): List<HrSample> = (0 until (a?.length() ?: 0)).map {
        val p = a!!.getJSONArray(it)
        HrSample(deviceId = "parity", ts = p.getLong(0), bpm = p.getInt(1))
    }

    private fun doubles(a: JSONArray) = (0 until a.length()).map { a.getDouble(it) }
    private fun strings(a: JSONArray) = (0 until a.length()).map { a.getString(it) }
    private fun bools(a: JSONArray) = (0 until a.length()).map { a.getBoolean(it) }
    private fun obj(vararg pairs: Pair<String, Any?>): Map<String, Any?> = mapOf(*pairs)

    /** Each oracle's Kotlin runner: the input as JSON, the answer as plain values (maps, lists, numbers, null). */
    private val runners: Map<String, (JSONObject) -> Any?> = mapOf(
        "StagePercentages.wholePercentages" to { i -> StagePercentages.wholePercentages(doubles(i.getJSONArray("parts"))) },
        "HeartRateRecovery.calculate" to { i ->
            HeartRateRecovery.calculate(hr(i.getJSONArray("hr")), i.getLong("start"), i.getLong("end"), i.getDouble("maxHr"))
                ?.let { obj("endHr" to it.endHr, "after1Minute" to it.after1Minute, "after2Minutes" to it.after2Minutes,
                            "after5Minutes" to it.after5Minutes) }
        },
        "StreakCalculator.streaks" to { i ->
            StreakCalculator.streaks(strings(i.getJSONArray("days")), bools(i.getJSONArray("qualified")), i.getString("today"))
                .let { obj("current" to it.current, "longest" to it.longest) }
        },
        "CircadianEngine.bodyClock" to { i ->
            val t = i.getDouble("tempMin")
            val w = CircadianEngine.idealSleepWindow(t, i.getDouble("duration"))
            obj("chronotype" to CircadianEngine.chronotype(t).raw, "bed" to w?.bedHour, "wakeHour" to w?.wakeHour,
                "offset" to CircadianEngine.sleepWindowOffsetHours(t, i.getDouble("wake")))
        },
        "ActivityHeatmap.build" to { i ->
            val v = i.getJSONObject("values")
            val values = v.keys().asSequence().associateWith { v.getDouble(it) }
            val g = ActivityHeatmap.build(values, i.getString("today"), i.getInt("weeks"))
            obj("weeks" to g.weeks, "scale" to g.scale,
                "columns" to g.columns.map { col -> col.map { c -> obj("day" to c.day, "value" to c.value, "level" to c.level) } })
        },
    )

    private fun oracleDir(): File {
        val url = javaClass.classLoader!!.getResource("core_parity") ?: error("core_parity oracles not on the test classpath")
        return File(url.toURI())
    }

    @Test
    fun theKotlinCopiesGiveTheSwiftAnswers() {
        val files = oracleDir().listFiles { f -> f.name.endsWith(".json") }!!.sortedBy { it.name }
        assertTrue("no oracles found", files.isNotEmpty())
        val failures = mutableListOf<String>()
        for (file in files) {
            val oracle = JSONObject(file.readText())
            val name = oracle.getString("function")
            val run = runners[name] ?: run { failures += "$name: no Kotlin runner"; null } ?: continue
            val cases = oracle.getJSONArray("cases")
            for (k in 0 until cases.length()) {
                val c = cases.getJSONObject(k)
                val result = runCatching { run(c.getJSONObject("input")) }
                val thrown = result.exceptionOrNull()
                if (thrown != null) {
                    failures += "$name case $k threw ${thrown.javaClass.simpleName}: ${thrown.message}"
                    continue
                }
                val diff = differ(c.opt("output"), result.getOrNull(), "")
                if (diff != null) failures += "$name case $k: $diff"
            }
        }
        if (failures.isNotEmpty()) fail("${failures.size} differences:\n" + failures.take(40).joinToString("\n"))
    }

    /** The first place [expected] (JSON) and [actual] (Kotlin values) disagree, numbers to a relative 1e-9; null if none. */
    private fun differ(expected: Any?, actual: Any?, path: String): String? {
        val e = if (expected == JSONObject.NULL) null else expected
        val a = if (actual is Enum<*>) actual.name else actual
        if (e == null || a == null) return if (e == null && a == null) null else "$path: expected $e, got $a"
        if (e is Number || a is Number) {
            val x = (e as? Number)?.toDouble() ?: return "$path: expected $e, got $a"
            val y = (a as? Number)?.toDouble() ?: return "$path: expected $e, got $a"
            return if (kotlin.math.abs(x - y) <= 1e-9 * maxOf(1.0, kotlin.math.abs(x))) null else "$path: expected $x, got $y"
        }
        if (e is JSONArray) {
            val list = (a as? List<*>) ?: return "$path: expected a list, got $a"
            if (list.size != e.length()) return "$path: expected ${e.length()} items, got ${list.size}"
            for (idx in list.indices) differ(e.opt(idx), list[idx], "$path[$idx]")?.let { return it }
            return null
        }
        if (e is JSONObject) {
            val map = (a as? Map<*, *>) ?: return "$path: expected an object, got $a"
            for (key in e.keys()) differ(e.opt(key), map[key], "$path.$key")?.let { return it }
            return null
        }
        return if (e == a) null else "$path: expected $e, got $a"
    }

    @Test
    fun theDifferenceCheckSeesADifference() {
        assertEquals(null, differ(JSONArray("[1, 2.5]"), listOf(1, 2.5), ""))
        assertTrue(differ(JSONArray("[1, 2.5]"), listOf(1, 2.6), "") != null)
    }
}
