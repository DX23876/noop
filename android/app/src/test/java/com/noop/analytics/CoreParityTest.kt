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

    /** A daily row from its Codable-shaped JSON. */
    private fun daily(o: JSONObject): com.noop.data.DailyMetric {
        fun d(k: String) = if (!o.has(k) || o.isNull(k)) null else o.getDouble(k)
        return com.noop.data.DailyMetric(deviceId = "parity", day = o.getString("day"), totalSleepMin = d("totalSleepMin"),
            recovery = d("recovery"), avgHrv = d("avgHrv"), restingHr = d("restingHr")?.toInt(), strain = d("strain"),
            respRateBpm = d("respRateBpm"), skinTempDevC = d("skinTempDevC"))
    }
    private fun dailies(a: JSONArray) = (0 until a.length()).map { daily(a.getJSONObject(it)) }

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
        "CoachSuggestions.suggestions" to { i ->
            CoachSuggestions.suggestions(if (i.isNull("today")) null else daily(i.getJSONObject("today")), dailies(i.getJSONArray("recent")))
        },
        "EffectRanker.rank" to { i ->
            fun sets(o: JSONObject) = o.keys().asSequence().associateWith { k -> strings(o.getJSONArray(k)).toSet() }
            val out = i.getJSONObject("outcome")
            EffectRanker.rank(sets(i.getJSONObject("behaviors")), sets(i.getJSONObject("controls")),
                              out.keys().asSequence().associateWith { out.getDouble(it) }, "charge").map {
                obj("behavior" to it.behavior, "lag" to it.lag, "delta" to it.effect.delta, "d" to it.effect.cohensD,
                    "p" to it.effect.pApprox, "n" to it.effect.nWith, "nWithout" to it.effect.nWithout,
                    "adjustedP" to it.adjustedP, "fdr" to it.fdrSignificant, "confidence" to it.confidence.raw)
            }
        },
        "StrapComparison.compare" to { i ->
            // Swift spells the case `restingHR`; every other kind is the plain camel case.
            fun swiftName(kind: MetricArbitrationPolicy.MetricKind) =
                if (kind == MetricArbitrationPolicy.MetricKind.RESTING_HR) "restingHR" else camel(kind.name)
            fun kinds(o: JSONObject) = o.keys().asSequence().mapNotNull { k ->
                MetricArbitrationPolicy.MetricKind.entries.firstOrNull { swiftName(it) == k }?.let { it to o.getDouble(k) }
            }.toMap()
            StrapComparison.compare(kinds(i.getJSONObject("a")), kinds(i.getJSONObject("b"))).map {
                obj("metric" to swiftName(it.metric), "a" to it.a, "b" to it.b, "agreement" to camel(it.agreement.name))
            }
        },
        "HypnogramCoverage.isHoled" to { i ->
            HypnogramCoverage.isHoled(if (i.isNull("stages")) null else i.getString("stages"), i.getDouble("span"))
        },
        "SleepWindowReclip.reclip" to { i ->
            SleepWindowReclip.reclip(i.getString("stages"), i.getLong("start"), i.getLong("oldEnd"), i.getLong("newStart"),
                                     i.getLong("newEnd"))?.let(::canonical)
        },
        "DaytimeBaselines" to { i ->
            val tz = i.getLong("tz")
            val days = i.getJSONArray("days")
            val aggregates = (0 until days.length()).map { k ->
                val d = days.getJSONObject(k)
                val rr = d.getJSONArray("rr").let { a -> (0 until a.length()).map { a.getJSONArray(it).let { p ->
                    com.noop.data.RrInterval(deviceId = "parity", ts = p.getLong(0), rrMs = p.getInt(1)) } } }
                DaytimeBaselines.dayDaytimeAggregate(hr(d.getJSONArray("hr")), rr, tz)
            }
            val mode: Any = when (val m = DaytimeBaselines.scoringModeFromAggregates(aggregates)) {
                is DaytimeStress.ScoringMode.BaselineRelative ->
                    obj("hr" to m.hr.baseline, "hrSpread" to m.hr.spread, "rmssd" to m.rmssd?.baseline, "rmssdSpread" to m.rmssd?.spread)
                else -> "dayRelative"
            }
            obj("aggregates" to aggregates.map { obj("hr" to it.hr, "rmssd" to it.rmssd) }, "mode" to mode)
        },
        "ActivityCostEngine.evaluate" to { i ->
            val sp = i.getJSONObject("sports"); val rec = i.getJSONObject("recovery")
            ActivityCostEngine.evaluate(sp.keys().asSequence().associateWith { strings(sp.getJSONArray(it)).toSet() },
                                        rec.keys().asSequence().associateWith { rec.getDouble(it) }).map {
                obj("sport" to it.sport, "delta" to it.delta, "next" to it.meanNextMorning, "base" to it.baselineMean)
            }
        },
        "SleepEdits" to { i ->
            fun session(a: JSONArray) = com.noop.data.SleepSession(deviceId = "parity", startTs = a.getLong(0), endTs = a.getLong(1),
                startTsAdjusted = a.getLong(2).takeIf { it >= 0 })
            val x = session(i.getJSONArray("a")); val y = session(i.getJSONArray("b"))
            val w = SleepEditGuard.clampedEditWindow(x.startTs, x.endTs, i.getLong("now"))
            val g = SleepGroupEdit.groupWindow(listOf(x, y))
            obj("duplicate" to SleepSessionDedup.isDuplicate(x, y),
                "keyed" to SleepSessionDedup.safeKeyedStart(i.getLong("onset"), x.startTs, x.endTs),
                "edit" to w?.let { listOf(it.first, it.second) }, "group" to g?.let { listOf(it.first, it.second) })
        },
        "StressOnsetDetector" to { i ->
            val config = StressOnsetDetector.Config(enabled = i.getBoolean("enabled"), autoNudge = i.getBoolean("auto"),
                                                    quietHoursEnabled = i.getBoolean("quiet"))
            var state = StressOnsetDetector.State()
            val steps = i.getJSONArray("steps")
            (0 until steps.length()).map { k ->
                val st = steps.getJSONObject(k)
                val rr = st.getJSONArray("rr").let { a -> (0 until a.length()).map { a.getInt(it) } }
                val d = StressOnsetDetector.evaluate(rr, if (st.isNull("hr")) null else st.getDouble("hr"),
                    if (st.isNull("motion")) null else st.getDouble("motion"), st.getBoolean("session"), state, config,
                    st.getLong("now"), i.getLong("tz"))
                state = d.nextState
                obj("nudge" to d.shouldNudge, "reason" to camel(d.reason.name), "fast" to d.fastRMSSD, "baseline" to d.baselineRMSSD,
                    "stateBaseline" to state.baselineRMSSD, "below" to state.wasBelow, "last" to state.lastFireAt,
                    "pending" to state.pendingEdgeAt)
            }
        },
        "SedentaryDetector" to { i ->
            val config = SedentaryConfig(enabled = true, notificationsMasterOn = true, thresholdMinutes = i.getInt("threshold"))
            var state = SedentaryState()
            val steps = i.getJSONArray("steps")
            (0 until steps.length()).map { k ->
                val st = steps.getJSONObject(k)
                val g = st.getJSONArray("g").let { a -> (0 until a.length()).map { a.getJSONArray(it).let { p ->
                    com.noop.data.GravitySample(deviceId = "parity", ts = p.getDouble(0).toLong(), x = p.getDouble(1),
                                                y = p.getDouble(2), z = p.getDouble(3)) } } }
                val d = SedentaryDetector.evaluate(g, state, config, st.getBoolean("worn"), st.getLong("now"), i.getLong("tz"))
                state = d.nextState
                obj("buzz" to d.shouldBuzz, "bout" to d.bout?.let { listOf(it.start, it.end) },
                    "processed" to state.lastProcessedGravityTs, "lastBuzz" to state.lastBuzzAt)
            }
        },
        "FusionResolver.resolve" to { i ->
            val raw = i.getJSONArray("inputs")
            val inputs = (0 until raw.length()).map { k -> raw.getJSONObject(k).let { o ->
                FusionInput(FusionSource.entries.first { it.id == o.getString("source") }, o.getDouble("value")) } }
            FusionResolver.resolve(i.getString("key"), inputs)?.let { p ->
                obj("value" to p.value, "winner" to p.winningSource.id, "agreement" to camel(p.agreement.name),
                    "contributors" to p.contributors.map { obj("source" to it.source.id, "value" to it.value, "tier" to it.tier,
                                                               "priority" to it.sourcePriority, "reason" to it.reason) })
            }
        },
        "WeeklyDigestEngine.build" to { i ->
            val raw = i.getJSONObject("by")
            val by = raw.keys().asSequence().associate { k ->
                WeeklyMetric.entries.first { it.key == k } to raw.getJSONObject(k).let { o -> o.keys().asSequence().associateWith { o.getDouble(it) } }
            }
            val d = WeeklyDigestEngine.build(by, i.getString("anchor"), i.getDouble("factor"))
            obj("start" to d.weekStart, "end" to d.weekEnd, "days" to d.daysWithData, "sleepSD" to d.sleepConsistencySD,
                "balance" to d.balance.name.lowercase(), "focal" to d.focalPoints,
                "metrics" to d.metrics.map { obj("metric" to it.metric.key, "mean" to it.thisWeek.mean, "median" to it.thisWeek.median,
                                                 "delta" to it.weekOverWeek.delta, "baseline" to it.baselineMean, "vs" to it.vsBaseline) })
        },
        "ChargeBaselines.resolve" to { i ->
            val res = ChargeBaselines.resolve(dailies(i.getJSONArray("imported")), dailies(i.getJSONArray("own")), i.getString("scoredDay"),
                                              i.getDouble("hrvEpoch"), i.getDouble("recEpoch"))
            fun st(s: BaselineState) = obj("baseline" to s.baseline, "spread" to s.spread, "n" to s.nValid, "status" to s.status.name.lowercase())
            fun hist(h: ChargeBaselines.History) = obj("days" to h.dayKeys, "values" to h.values)
            obj("hrv" to st(res.hrv), "rhr" to st(res.restingHR), "resp" to st(res.resp), "hrvHistory" to hist(res.hrvHistory),
                "rhrHistory" to hist(res.restingHRHistory), "respHistory" to hist(res.respHistory))
        },
        "ChargeDrivers.chargeDrivers" to { i ->
            fun b(k: String): BaselineState? = if (i.isNull(k)) null else i.getJSONArray(k).let { v ->
                BaselineState(baseline = v.getDouble(0), spread = v.getDouble(1), nValid = v.getInt(2), nightsSinceUpdate = 0,
                              status = if (v.getInt(2) >= 14) BaselineStatus.TRUSTED else BaselineStatus.PROVISIONAL)
            }
            RecoveryDrivers.chargeDrivers(i.getDouble("hrv"), i.getDouble("rhr"), if (i.isNull("resp")) null else i.getDouble("resp"),
                b("hrvB")!!, b("rhrB"), b("respB"), if (i.isNull("sleep")) null else i.getDouble("sleep"),
                if (i.isNull("skin")) null else i.getDouble("skin")).map { it.deltaPoints }
        },
        "BreathPacer.schedule" to { i ->
            BreathPacer.schedule(i.getDouble("bpm"), i.getDouble("inhale"), i.getInt("cycles"))
                .map { obj("offset" to it.offsetMs, "phase" to it.phase.name.lowercase(), "loops" to it.loops, "label" to it.label) }
        },
        "ImuFeatureExtractor.extract" to { i ->
            val raw = i.getJSONArray("samples")
            val f = ImuFeatureExtractor.extract((0 until raw.length()).map { k -> raw.getJSONArray(k).let {
                com.noop.protocol.RawImuSample(it.getDouble(0), it.getDouble(1), it.getDouble(2), it.getDouble(3), it.getDouble(4), it.getDouble(5)) } },
                i.getInt("hz"))
            obj("accel" to f.accelEnergyG, "gyro" to f.gyroEnergyDps, "jerk" to f.jerkRms, "cadence" to f.cadenceHz,
                "strength" to f.cadenceStrength, "n" to f.sampleCount)
        },
        "DoseResponseEngine.estimate" to { i ->
            val dose = i.getJSONObject("dose"); val out = i.getJSONObject("outcome")
            DoseResponseEngine.estimate(DosedBehavior.entries.first { it.raw == i.getString("behavior") },
                dose.keys().asSequence().associateWith { dose.getInt(it) }, out.keys().asSequence().associateWith { out.getDouble(it) })
                ?.let { d -> obj("perUnit" to d.perUnit, "user" to d.userSlope, "prior" to d.priorSlope, "weight" to d.weight, "n" to d.nUser,
                                 "priorDominated" to d.priorDominated, "contradicts" to d.contradictsPrior, "confidence" to d.confidence.raw,
                                 "curve" to d.curve.map { it.dose }) }
        },
        "HRVFreqDomain.freqDomain" to { i ->
            HrvFreqDomain.freqDomainRaw(doubles(i.getJSONArray("rr")))
                ?.let { obj("lf" to it.lf, "hf" to it.hf, "lfhf" to it.lfhf, "total" to it.totalPower) }
        },
        "HydrationGoal.dailyGoal" to { i ->
            HydrationGoal.dailyGoalMl(i.getString("sex"), if (i.isNull("effort")) null else i.getDouble("effort"))
        },
        "SleepStageTotals.groups" to { i ->
            val b = i.getJSONArray("blocks")
            val blocks = (0 until b.length()).map { k -> b.getJSONArray(k).let { SleepStageTotals.NightBlock(it.getLong(0), it.getLong(1)) } }
            val off = i.getLong("offset")
            obj("groups" to SleepStageTotals.bridgedNightGroups(blocks, off).map { g ->
                    obj("indices" to g.indices, "gaps" to g.gaps.map { listOf(it.first, it.second) }) },
                "main" to SleepStageTotals.mainNightGroupIndices(blocks, off, if (i.isNull("habitual")) null else i.getLong("habitual")),
                "clamped" to SleepStageTotals.clampStagesToOnset(if (i.isNull("stages")) null else i.getString("stages"), i.getLong("onset"))
                    ?.let(::canonical))
        },
        "WorkoutDetector.activitySeries" to { i ->
            val g = i.getJSONArray("g")
            WorkoutDetector.activitySeries((0 until g.length()).map { k -> g.getJSONArray(k).let {
                com.noop.data.GravitySample(deviceId = "parity", ts = it.getDouble(0).toLong(), x = it.getDouble(1), y = it.getDouble(2), z = it.getDouble(3)) } })
                .map { listOf(it.ts, it.intensity) }
        },
        "IllnessSignalEngine.evaluate" to { i ->
            fun reading(k: String) = if (i.isNull(k)) null else IllnessSignalEngine.SignalReading(i.getDouble(k))
            val c = i.getJSONArray("ctx").let { a -> (0 until a.length()).map { a.getBoolean(it) } }
            val res = IllnessSignalEngine.evaluate(
                IllnessSignalEngine.Inputs(reading("rhr"), reading("skin"), reading("hrv"), reading("resp")),
                IllnessSignalEngine.Context(c[0], c[1], c[2], c[3], c[4], c[5], c[6]))
            // The Kotlin copy has no typed suppression reasons (Swift added them for its own wording); the
            // labels in suppressedBy carry the same facts, so the reasons are left out of the comparison.
            obj("score" to res.score, "level" to res.level.raw, "fired" to res.firedSignals, "suppressedBy" to res.suppressedBy)
        },
    )

    /** A JSON text as plain values, so key order and number spelling cannot differ between encoders. */
    private fun canonical(text: String): Any? = plain(if (text.trimStart().startsWith("[")) JSONArray(text) else JSONObject(text))

    private fun plain(v: Any?): Any? = when (v) {
        is JSONArray -> (0 until v.length()).map { plain(v.opt(it)) }
        is JSONObject -> v.keys().asSequence().associateWith { plain(v.opt(it)) }
        JSONObject.NULL -> null
        else -> v
    }

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
