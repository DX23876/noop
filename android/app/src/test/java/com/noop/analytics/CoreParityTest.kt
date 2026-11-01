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

    /** A Kotlin SCREAMING_CASE name as the Swift case name it mirrors (`NO_DATA` → `noData`). */
    private fun camel(name: String): String = name.lowercase().split('_')
        .mapIndexed { k, w -> if (k == 0) w else w.replaceFirstChar { it.uppercase() } }.joinToString("")

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
        "SleepDebt" to { i ->
            val rows = i.getJSONArray("series")
            val series = (0 until rows.length()).map { k ->
                val row = rows.getJSONObject(k)
                row.getString("day") to (if (row.isNull("min")) null else row.getDouble("min"))
            }
            val need = i.getDouble("need")
            val window = i.getInt("window")
            val imp = i.getJSONObject("imported")
            val ledger = SleepDebt.ledger(series, need, window)
            obj("credited" to SleepDebt.creditedSleepMin(if (i.isNull("main")) null else i.getDouble("main"), i.getDouble("nap")),
                "series" to SleepDebt.debtSeries(series, need, imp.keys().asSequence().associateWith { imp.getDouble(it) }, window)
                    .map { obj("day" to it.first, "value" to it.second) },
                "balance" to ledger.balanceMin, "needMin" to ledger.needMin,
                "nights" to ledger.nights.map { obj("day" to it.day, "slept" to it.sleptMin, "delta" to it.deltaMin) })
        },
        "StressIndex.components" to { i ->
            StressIndex.componentsRaw(doubles(i.getJSONArray("rr")))
                ?.let { obj("mo" to it.moSec, "amo" to it.aMoPercent, "mxdmn" to it.mxDMnSec, "si" to it.si) }
        },
        "VitalityEngine" to { i ->
            fun d(k: String) = if (i.isNull(k)) null else i.getDouble(k)
            val inputs = VitalityEngine.Inputs(i.getDouble("age"), d("rhr"), d("vo2"), d("evo2"), d("sleep"), d("cons"),
                                               d("rmssd"), d("rnorm"), d("steps"))
            obj("norm" to VitalityEngine.rmssdNorm(i.getDouble("age")),
                "consistency" to VitalityEngine.sleepConsistency(doubles(i.getJSONArray("nightly"))),
                "contributions" to VitalityEngine.contributions(inputs).map { obj("key" to it.key, "label" to it.label, "lnHazard" to it.lnHazard) },
                "result" to VitalityEngine.compute(inputs)?.let {
                    obj("vitality" to it.vitality, "bodyAge" to it.bodyAge, "deltaYears" to it.deltaYears, "bandYears" to it.bandYears)
                })
        },
        "FitnessAgeEngine" to { i ->
            val age = i.getDouble("age"); val sex = i.getString("sex"); val rhr = i.getDouble("rhr")
            val pa = FitnessAgeEngine.physicalActivityIndexFromStrain(i.getInt("days"), i.getDouble("strain"))
            obj("bmi" to FitnessAgeEngine.bmi(i.getDouble("weight"), i.getDouble("height")), "pa" to pa,
                "vo2" to FitnessAgeEngine.estimateVO2max(age, sex, i.getDouble("waist"), rhr, pa),
                "fitnessAge" to FitnessAgeEngine.fitnessAge(age, sex, rhr, pa),
                "nightsUntilReady" to FitnessAgeEngine.nightsUntilReady(i.getInt("rhrDays")))
        },
        "HRZones" to { i ->
            val set = HrZones.zones(maxHR = i.getDouble("maxHR"))
            val t = HrZones.timeInZone(hr(i.getJSONArray("hr")), set)
            obj("zones" to set.zones.map { obj("n" to it.number, "lower" to it.lower, "upper" to it.upper, "pct" to it.lowerPct) },
                "maxHR" to set.maxHR, "seconds" to t.seconds, "below" to t.belowZone1)
        },
        "HRVAnalyzer.rmssdRaw" to { i -> HrvAnalyzer.rmssdRaw(doubles(i.getJSONArray("nn"))) },
        "DaytimeStress.analyze" to { i ->
            val rrRows = i.getJSONArray("rr")
            val rr = (0 until rrRows.length()).map { k ->
                val p = rrRows.getJSONArray(k)
                com.noop.data.RrInterval(deviceId = "parity", ts = p.getLong(0), rrMs = p.getInt(1))
            }
            val res = DaytimeStress.analyze(hr(i.getJSONArray("hr")), rr, tzOffsetSeconds = i.getLong("tz"))
            obj("hours" to res.hours.map { obj("hour" to it.hour, "startTs" to it.startTs, "level" to it.level,
                                               "meanHR" to it.meanHr, "rmssd" to it.rmssd) },
                "sustainedHigh" to res.sustainedHigh, "sustainedRun" to res.sustainedRun, "dayMean" to res.dayMean,
                "peakHour" to res.peak?.hour)
        },
        "TrainingLoadEngine.evaluate" to { i ->
            val rows = i.getJSONArray("days")
            val days = (0 until rows.length()).map { k ->
                val row = rows.getJSONObject(k)
                TrainingLoadEngine.DailyLoad(row.getString("day"), if (row.isNull("load")) null else row.getDouble("load"))
            }
            val res = TrainingLoadEngine.evaluate(days)
            obj("state" to res.state.name.lowercase(), "reason" to res.unavailableReason?.name?.let(::camel),
                "contiguous" to res.contiguousDays, "start" to res.startDay, "end" to res.endDay,
                "points" to res.points.map { obj("day" to it.day, "load" to it.load, "ctl" to it.chronicLoad,
                                                 "atl" to it.acuteLoad, "balance" to it.balance) })
        },
        "BatteryEstimator.estimate" to { i ->
            val rows = i.getJSONArray("samples")
            val samples = (0 until rows.length()).map { k -> rows.getJSONArray(k).let { it.getDouble(0).toLong() to it.getDouble(1) } }
            BatteryEstimator.estimate(samples, i.getDouble("rated"))
                ?.let { obj("remaining" to it.remainingHours, "source" to it.source.name.lowercase(), "soc" to it.currentSoc) }
        },
        "RecoveryForecaster.forecast" to { i ->
            RecoveryForecaster.forecast(doubles(i.getJSONArray("charge")), doubles(i.getJSONArray("effort")),
                if (i.isNull("today")) null else i.getDouble("today"), i.getDouble("planned"),
                if (i.isNull("need")) null else i.getDouble("need"), i.getInt("needNights"))
                ?.let { obj("charge" to it.charge, "band" to it.band, "baseline" to it.baseline, "planned" to it.plannedSleepHours) }
        },
        "Baselines" to { i ->
            val cfg = when (i.getString("kind")) { "hrv" -> Baselines.hrvCfg; "rhr" -> Baselines.restingHRCfg; else -> Baselines.respCfg }
            val days = strings(i.getJSONArray("days")); val today = i.getString("today")
            val raw = i.getJSONArray("values")
            val values = (0 until raw.length()).map { if (raw.isNull(it)) null else raw.getDouble(it) }
            fun state(s: BaselineState) = obj("baseline" to s.baseline, "spread" to s.spread, "n" to s.nValid,
                                              "since" to s.nightsSinceUpdate, "status" to s.status.name.lowercase())
            val coverage = Baselines.recentHrvCoverage(days, values, today)
            obj("fold" to state(Baselines.foldHistory(values, cfg)),
                "foldEpoch" to state(Baselines.foldHistory(values, days, cfg, i.getDouble("epoch"))),
                "cutoff" to Baselines.cutoffKey(today, i.getInt("carry")),
                "observed" to coverage.observed, "missing" to coverage.missing,
                "since" to Baselines.nightsSinceNewestValidNight(days, values, today))
        },
        "StepsCounter.stepsInWindow" to { i ->
            val rows = i.getJSONArray("rows")
            StepsCounter.stepsInWindow((0 until rows.length()).map { k ->
                val r = rows.getJSONObject(k)
                com.noop.data.StepSample(deviceId = "parity", ts = r.getLong("ts"), counter = r.getInt("counter"),
                                         activityClass = if (r.isNull("cls")) null else r.getInt("cls"))
            })
        },
        "HRVReadiness.evaluate" to { i ->
            val raw = i.getJSONArray("hrv")
            HRVReadiness.evaluate((0 until raw.length()).map { if (raw.isNull(it)) null else raw.getDouble(it) })
                ?.let { obj("tier" to camel(it.tier.name), "baseline" to it.baseline7Ms, "low" to it.normalLowMs, "high" to it.normalHighMs) }
        },
        "StepsEstimateEngine.estimate" to { i ->
            StepsEstimateEngine.estimate(i.getDouble("motion"),
                StepsEstimateEngine.Calibration(coefficient = i.getDouble("coefficient"), sampleDays = 10, confidence = 0.5, manual = false))
        },
        "SleepStageTotals.mainNightIndex" to { i ->
            val b = i.getJSONArray("blocks")
            SleepStageTotals.mainNightIndex((0 until b.length()).map { k -> b.getJSONArray(k).let { SleepStageTotals.NightBlock(it.getLong(0), it.getLong(1)) } },
                i.getLong("offset"), if (i.isNull("habitual")) null else i.getLong("habitual"))
        },
        "RhythmScreener" to { i ->
            val w = i.getJSONArray("windows")
            val results = (0 until w.length()).map { k ->
                val x = w.getJSONObject(k)
                RhythmScreener.screenWindow(RhythmScreener.WindowInput(
                    rrMs = doubles(x.getJSONArray("rr")),
                    ts = x.getJSONArray("ts").let { a -> (0 until a.length()).map { a.getInt(it) } },
                    ppgIBIms = if (x.isNull("ppg")) null else doubles(x.getJSONArray("ppg")),
                    motionStill = x.getBoolean("still"), meanHR = x.getDouble("hr")))
            }
            val night = RhythmScreener.summarizeNight(results)
            obj("windows" to results.map { obj("label" to it.label.raw, "sd1" to it.sd1, "sd2" to it.sd2, "ratio" to it.sd1sd2,
                                               "norm" to it.normRmssd, "tpr" to it.turningPointRate, "ectopic" to it.ectopicFraction,
                                               "n" to it.nBeats, "confidence" to it.confidence.name.lowercase(),
                                               "agreed" to it.agreedAcrossSources) },
                "readable" to night.readableWindows, "steady" to night.steadyWindows, "occasional" to night.occasionalWindows,
                "varied" to night.variedWindows, "recurred" to night.variationRecurred, "overall" to night.overall.raw)
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
