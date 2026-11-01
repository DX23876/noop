import Foundation
import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// Fork (DX23876), Android without Room (`docs/fork/android/CORE-ONLY-PLAN.md`): synthetic cross-checks of the Kotlin
/// copies Android's screens still run against the Swift code iOS runs. Each oracle holds generated inputs and the
/// Swift answers, under `android/app/src/test/resources/core_parity/`; `CoreParityTest.kt` runs the Kotlin copy over
/// the same inputs and compares. This test fails when Swift no longer gives the committed answers, so a change on
/// either side breaks one of the two. Rewrite the oracles with `NOOP_WRITE_PARITY=1 swift test --filter CoreParity`.
final class CoreParityOracleTests: XCTestCase {
    /// SplitMix64: the same numbers on every run.
    struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
        mutating func double(_ range: ClosedRange<Double>) -> Double {
            let unit = Double(next() >> 11) / Double(1 << 53)
            return (range.lowerBound + unit * (range.upperBound - range.lowerBound) * 1000).rounded() / 1000
        }
        mutating func chance(_ p: Double) -> Bool { double(0...1) < p }
    }

    struct Oracle {
        let name: String
        let inputs: [[String: Any]]
        let run: ([String: Any]) -> Any
    }

    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("android/app/src/test/resources/core_parity", isDirectory: true)

    static func day(_ epochDay: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochDay) * 86_400)
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func hrSeries(_ r: inout Rand, from: Int, seconds: Int, step: Int, base: Int) -> [[Int]] {
        stride(from: from, to: from + seconds, by: step).map { [$0, max(35, min(220, base + r.int(-25...25)))] }
    }

    /// An optional as JSON: the value or null.
    static func nn(_ v: Any?) -> Any { v ?? NSNull() }

    static func hr(_ any: Any?) -> [HRSample] {
        (any as? [[Int]] ?? []).map { HRSample(ts: $0[0], bpm: $0[1]) }
    }

    /// A daily row as JSON in `DailyMetric`'s Codable shape, with gaps.
    static func dailyRow(_ r: inout Rand, day d: String) -> [String: Any] {
        func maybe(_ range: ClosedRange<Double>) -> Any { r.chance(0.2) ? NSNull() : r.double(range) }
        return ["day": d, "totalSleepMin": maybe(180...600), "recovery": maybe(1...99), "avgHrv": maybe(15...150),
                "restingHr": r.chance(0.2) ? NSNull() : r.int(40...85), "strain": maybe(0...100),
                "respRateBpm": maybe(11...20), "skinTempDevC": maybe(-1.5...1.5)]
    }

    static func dailyRows(_ any: Any?) -> [DailyMetric] {
        guard let any, let data = try? JSONSerialization.data(withJSONObject: any) else { return [] }
        return (try? JSONDecoder().decode([DailyMetric].self, from: data)) ?? []
    }

    /// A stage list in the stored `stagesJSON` array shape: `[{"start":…,"end":…,"stage":…}]`, with gaps.
    static func stagesJSON(_ r: inout Rand, from: Int, to: Int) -> String {
        var t = from, rows: [String] = []
        while t < to {
            let len = r.int(60...2_400), end = min(to, t + len)
            if r.chance(0.85) {
                rows.append("{\"start\":\(t),\"end\":\(end),\"stage\":\"\(["light", "deep", "rem", "awake"][r.int(0...3)])\"}")
            }
            t = end + (r.chance(0.2) ? r.int(60...3_600) : 0)
        }
        return "[" + rows.joined(separator: ",") + "]"
    }

    /// A JSON text re-encoded with sorted keys, so two encoders' key orders cannot differ.
    static func canonicalJSON(_ text: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? text
    }

    static func cases(_ count: Int, seed: UInt64, _ make: (inout Rand) -> [String: Any]) -> [[String: Any]] {
        var r = Rand(state: seed)
        return (0..<count).map { _ in make(&r) }
    }

    static let oracles: [Oracle] = [
        Oracle(name: "StagePercentages.wholePercentages",
               inputs: cases(60, seed: 1) { r in ["parts": (0..<r.int(1...5)).map { _ in r.double(-10...300) }] },
               run: { nn(StagePercentages.wholePercentages($0["parts"] as! [Double])) }),
        Oracle(name: "HeartRateRecovery.calculate",
               inputs: cases(40, seed: 2) { r in
                   let start = 1_760_000_000 + r.int(0...86_400), end = start + r.int(600...5_400)
                   return ["hr": hrSeries(&r, from: start, seconds: end - start + 900, step: r.int(1...30), base: 140),
                           "start": start, "end": end, "maxHr": r.double(150...205)]
               },
               run: { a in
                   guard let res = HeartRateRecovery.calculate(samples: hr(a["hr"]), workoutStart: a["start"] as! Int,
                                                               workoutEnd: a["end"] as! Int, maxHR: a["maxHr"] as! Double)
                   else { return NSNull() }
                   return ["endHr": res.endHR, "after1Minute": nn(res.after1Minute),
                           "after2Minutes": nn(res.after2Minutes), "after5Minutes": nn(res.after5Minutes)]
               }),
        Oracle(name: "StreakCalculator.streaks",
               inputs: cases(40, seed: 3) { r in
                   let start = 20_000 + r.int(0...300), n = r.int(0...60)
                   let days = (0..<n).map { day(start + $0) }
                   return ["days": days, "qualified": days.map { _ in r.chance(0.7) },
                           "today": day(start + n - 1 + r.int(0...2))]
               },
               run: { a in
                   let s = StreakCalculator.streaks(dayKeys: a["days"] as! [String], qualified: a["qualified"] as! [Bool],
                                                    today: a["today"] as! String)
                   return ["current": s.current, "longest": s.longest]
               }),
        Oracle(name: "CircadianEngine.bodyClock",
               inputs: cases(60, seed: 4) { r in
                   ["tempMin": r.double(0...23.99), "duration": r.double(-1...25), "wake": r.double(0...23.99)]
               },
               run: { a in
                   let t = a["tempMin"] as! Double
                   let w = CircadianEngine.idealSleepWindow(tempMinHour: t, durationHours: a["duration"] as! Double)
                   return ["chronotype": CircadianEngine.chronotype(tempMinHour: t).rawValue,
                           "bed": nn(w?.bedHour), "wakeHour": nn(w?.wakeHour),
                           "offset": CircadianEngine.sleepWindowOffsetHours(tempMinHour: t, actualWakeHour: a["wake"] as! Double)]
               }),
        Oracle(name: "ActivityHeatmap.build",
               inputs: cases(20, seed: 5) { r in
                   let today = 20_100 + r.int(0...400)
                   var values: [String: Double] = [:]
                   for d in 0..<r.int(0...120) where r.chance(0.6) { values[day(today - d)] = r.double(0...1500) }
                   return ["values": values, "today": day(today), "weeks": r.int(1...20)]
               },
               run: { a in
                   let g = ActivityHeatmap.build(values: a["values"] as! [String: Double], today: a["today"] as! String,
                                                 weeks: a["weeks"] as! Int)
                   return ["weeks": g.weeks, "scale": g.scale,
                           "columns": g.columns.map { col in col.map { c in
                               ["day": nn(c.day), "value": nn(c.value), "level": c.level] as [String: Any]
                           } }]
               }),
        Oracle(name: "SleepDebt",
               inputs: cases(40, seed: 6) { r in
                   let start = 20_200 + r.int(0...200)
                   let series: [[String: Any]] = (0..<r.int(0...30)).map { d in
                       ["day": day(start + d), "min": r.chance(0.15) ? NSNull() : r.double(0...700)]
                   }
                   var imported: [String: Double] = [:]
                   for row in series where r.chance(0.2) { imported[row["day"] as! String] = r.double(-200...400) }
                   return ["series": series, "need": r.double(4...10), "window": r.int(1...21), "imported": imported,
                           "main": r.chance(0.2) ? NSNull() : r.double(-50...600), "nap": r.double(-20...120)]
               },
               run: { a in
                   let series = (a["series"] as! [[String: Any]]).map {
                       (day: $0["day"] as! String, totalSleepMin: $0["min"] as? Double)
                   }
                   let need = a["need"] as! Double, window = a["window"] as! Int
                   let ledger = SleepDebt.ledger(series: series, needHours: need, window: window)
                   return ["credited": nn(SleepDebt.creditedSleepMin(mainSleepMin: a["main"] as? Double,
                                                                     napSleepMin: a["nap"] as! Double)),
                           "series": SleepDebt.debtSeries(series: series, needHours: need,
                                                          importedDebtMin: a["imported"] as! [String: Double],
                                                          window: window).map { ["day": $0.day, "value": $0.value] },
                           "balance": ledger.balanceMin, "needMin": ledger.needMin,
                           "nights": ledger.nights.map { ["day": $0.day, "slept": $0.sleptMin, "delta": $0.deltaMin] }]
               }),
        Oracle(name: "StressIndex.components",
               inputs: cases(40, seed: 7) { r in
                   let base = r.double(500...1200)
                   return ["rr": (0..<r.int(0...300)).map { _ in r.chance(0.05) ? r.double(200...2500) : base + r.double(-120...120) }]
               },
               run: { a in
                   guard let c = StressIndex.components(rawRR: a["rr"] as! [Double]) else { return NSNull() }
                   return ["mo": c.moSec, "amo": c.aMoPercent, "mxdmn": c.mxDMnSec, "si": c.si]
               }),
        Oracle(name: "VitalityEngine",
               inputs: cases(40, seed: 8) { r in
                   func maybe(_ range: ClosedRange<Double>) -> Any { r.chance(0.25) ? NSNull() : r.double(range) }
                   return ["age": r.double(18...85), "rhr": maybe(40...90), "vo2": maybe(20...60), "evo2": maybe(25...50),
                           "sleep": maybe(4...10), "cons": maybe(0...1), "rmssd": maybe(10...120), "rnorm": maybe(20...80),
                           "steps": maybe(1000...20000),
                           "nightly": (0..<r.int(0...14)).map { _ in r.double(3...11) }]
               },
               run: { a in
                   let inputs = VitalityEngine.Inputs(
                       chronoAge: a["age"] as! Double, restingHR: a["rhr"] as? Double, vo2max: a["vo2"] as? Double,
                       expectedVO2max: a["evo2"] as? Double, sleepHours: a["sleep"] as? Double,
                       sleepConsistency: a["cons"] as? Double, rmssd: a["rmssd"] as? Double,
                       rmssdNorm: a["rnorm"] as? Double, steps: a["steps"] as? Double)
                   let result = VitalityEngine.compute(inputs)
                   return ["norm": VitalityEngine.rmssdNorm(forAge: a["age"] as! Double),
                           "consistency": nn(VitalityEngine.sleepConsistency(nightlyHours: a["nightly"] as! [Double])),
                           "contributions": VitalityEngine.contributions(inputs).map {
                               ["key": $0.key, "label": $0.label, "lnHazard": $0.lnHazard] },
                           "result": nn(result.map { ["vitality": $0.vitality, "bodyAge": $0.bodyAge,
                                                       "deltaYears": $0.deltaYears, "bandYears": $0.bandYears] })]
               }),
        Oracle(name: "FitnessAgeEngine",
               inputs: cases(50, seed: 9) { r in
                   ["age": r.double(18...85), "sex": ["male", "female", "nonbinary"][r.int(0...2)],
                    "waist": r.double(60...130), "rhr": r.double(40...95), "days": r.int(0...7),
                    "strain": r.double(0...100), "weight": r.double(45...150), "height": r.double(150...205),
                    "rhrDays": r.int(0...30)]
               },
               run: { a in
                   let age = a["age"] as! Double, sex = a["sex"] as! String, rhr = a["rhr"] as! Double
                   let pa = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: a["days"] as! Int,
                                                                            meanActiveStrain: a["strain"] as! Double)
                   return ["bmi": FitnessAgeEngine.bmi(weightKg: a["weight"] as! Double, heightCm: a["height"] as! Double),
                           "pa": pa,
                           "vo2": FitnessAgeEngine.estimateVO2max(age: age, sex: sex, waistCm: a["waist"] as! Double,
                                                                  restingHR: rhr, paIndex: pa),
                           "fitnessAge": FitnessAgeEngine.fitnessAge(age: age, sex: sex, restingHR: rhr, paIndex: pa),
                           "nightsUntilReady": FitnessAgeEngine.nightsUntilReady(rhrDays: a["rhrDays"] as! Int)]
               }),
        Oracle(name: "HRZones",
               inputs: cases(40, seed: 10) { r in
                   let start = 1_760_000_000
                   return ["maxHR": r.double(140...210),
                           "hr": hrSeries(&r, from: start, seconds: r.int(60...3_600), step: r.int(1...20), base: 120)]
               },
               run: { a in
                   let set = HRZones.zones(maxHR: a["maxHR"] as! Double)
                   let t = HRZones.timeInZone(hr(a["hr"]), zoneSet: set)
                   return ["zones": set.zones.map { ["n": $0.number, "lower": $0.lower, "upper": $0.upper, "pct": $0.lowerPct] },
                           "maxHR": set.maxHR, "seconds": t.seconds, "below": t.belowZone1]
               }),
        Oracle(name: "HRVAnalyzer.rmssdRaw",
               inputs: cases(50, seed: 11) { r in
                   let base = r.double(500...1300)
                   return ["nn": (0..<r.int(0...200)).map { _ in base + r.double(-150...150) }]
               },
               run: { a in nn(HRVAnalyzer.rmssdRaw(a["nn"] as! [Double])) }),
        Oracle(name: "DaytimeStress.analyze",
               inputs: cases(12, seed: 12) { r in
                   let start = 1_760_000_000 - 1_760_000_000 % 86_400 + r.int(0...6) * 3_600
                   let hrRows = hrSeries(&r, from: start, seconds: r.int(4...16) * 3_600, step: r.int(5...60), base: 75)
                   var ts = start, rr: [[Int]] = []
                   while ts < start + 12 * 3_600 {
                       if r.chance(0.8) { rr.append([ts, r.int(600...1100)]) }
                       ts += r.int(1...4)
                   }
                   return ["hr": hrRows, "rr": rr, "tz": [0, 3_600, -18_000, 19_800][r.int(0...3)]]
               },
               run: { a in
                   let rr = (a["rr"] as! [[Int]]).map { RRInterval(ts: $0[0], rrMs: $0[1]) }
                   let res = DaytimeStress.analyze(hr: hr(a["hr"]), rr: rr, tzOffsetSeconds: a["tz"] as! Int)
                   return ["hours": res.hours.map { ["hour": $0.hour, "startTs": $0.startTs, "level": nn($0.level),
                                                     "meanHR": nn($0.meanHR), "rmssd": nn($0.rmssd)] },
                           "sustainedHigh": res.sustainedHigh, "sustainedRun": res.sustainedRun,
                           "dayMean": nn(res.dayMean), "peakHour": nn(res.peak?.hour)]
               }),
        Oracle(name: "TrainingLoadEngine.evaluate",
               inputs: cases(30, seed: 13) { r in
                   let start = 20_000 + r.int(0...300)
                   let days: [[String: Any]] = (0..<r.int(0...90)).compactMap { d in
                       r.chance(0.9) ? ["day": day(start + d), "load": r.chance(0.1) ? NSNull() : r.double(0...150)] : nil
                   }
                   return ["days": days]
               },
               run: { a in
                   let days = (a["days"] as! [[String: Any]]).map {
                       TrainingLoadEngine.DailyLoad(day: $0["day"] as! String, load: $0["load"] as? Double)
                   }
                   let res = TrainingLoadEngine.evaluate(days: days)
                   return ["state": String(describing: res.state), "reason": nn(res.unavailableReason.map { String(describing: $0) }),
                           "contiguous": res.contiguousDays, "start": nn(res.startDay), "end": nn(res.endDay),
                           "points": res.points.map { ["day": $0.day, "load": $0.load, "ctl": $0.chronicLoad,
                                                       "atl": $0.acuteLoad, "balance": $0.balance] }]
               }),
        Oracle(name: "BatteryEstimator.estimate",
               inputs: cases(40, seed: 14) { r in
                   var ts = 1_760_000_000, soc = r.double(20...100)
                   var rows: [[Double]] = []
                   for _ in 0..<r.int(0...60) {
                       ts += r.int(300...7_200)
                       soc = r.chance(0.05) ? r.double(80...100) : max(0, soc - r.double(0...2))
                       rows.append([Double(ts), soc])
                   }
                   return ["samples": rows, "rated": r.double(48...200)]
               },
               run: { a in
                   let samples = (a["samples"] as! [[Double]]).map { (ts: Int($0[0]), soc: $0[1]) }
                   guard let e = BatteryEstimator.estimate(samples: samples, ratedHours: a["rated"] as! Double)
                   else { return NSNull() }
                   return ["remaining": e.remainingHours, "source": e.source.rawValue, "soc": e.currentSoc]
               }),
        Oracle(name: "RecoveryForecaster.forecast",
               inputs: cases(40, seed: 15) { r in
                   ["charge": (0..<r.int(0...30)).map { _ in r.double(0...100) },
                    "effort": (0..<r.int(0...30)).map { _ in r.double(0...100) },
                    "today": r.chance(0.2) ? NSNull() : r.double(0...100), "planned": r.double(3...11),
                    "need": r.chance(0.3) ? NSNull() : r.double(6...10), "needNights": r.int(0...14)]
               },
               run: { a in
                   guard let f = RecoveryForecaster.forecast(
                       recentCharge: a["charge"] as! [Double], recentEffort: a["effort"] as! [Double],
                       todayEffort: a["today"] as? Double, plannedSleepHours: a["planned"] as! Double,
                       needHours: a["need"] as? Double, needNights: a["needNights"] as! Int) else { return NSNull() }
                   return ["charge": f.charge, "band": f.band, "baseline": f.baseline, "planned": f.plannedSleepHours]
               }),
        Oracle(name: "Baselines",
               inputs: cases(40, seed: 16) { r in
                   let start = 20_300 + r.int(0...100), n = r.int(0...60)
                   let kind = ["hrv", "rhr", "resp"][r.int(0...2)]
                   let range: ClosedRange<Double> = kind == "hrv" ? 5...250 : kind == "rhr" ? 30...110 : 8...30
                   return ["kind": kind, "days": (0..<n).map { day(start + $0) },
                           "values": (0..<n).map { _ in r.chance(0.2) ? NSNull() as Any : r.double(range) as Any },
                           "today": day(start + n + r.int(0...5)), "epoch": r.chance(0.5) ? 0.0 : Double(start + n / 2) * 86_400,
                           "carry": r.int(0...10)]
               },
               run: { a in
                   let kind = a["kind"] as! String
                   let cfg = kind == "hrv" ? Baselines.hrvCfg : kind == "rhr" ? Baselines.restingHRCfg : Baselines.respCfg
                   let days = a["days"] as! [String], today = a["today"] as! String
                   let values = (a["values"] as! [Any]).map { $0 as? Double }
                   func state(_ s: BaselineState) -> [String: Any] {
                       ["baseline": s.baseline, "spread": s.spread, "n": s.nValid, "since": s.nightsSinceUpdate,
                        "status": s.status.rawValue]
                   }
                   let coverage = Baselines.recentHrvCoverage(dayKeys: days, nightlyHrv: values, today: today)
                   return ["fold": state(Baselines.foldHistory(values, cfg: cfg)),
                           "foldEpoch": state(Baselines.foldHistory(values, dayKeys: days, cfg: cfg,
                                                                    baselineEpoch: a["epoch"] as? Double)),
                           "cutoff": Baselines.cutoffKey(todayKey: today, carryDays: a["carry"] as! Int),
                           "observed": coverage.observed, "missing": coverage.missing,
                           "since": nn(Baselines.nightsSinceNewestValidNight(dayKeys: days, nightlyHrv: values, today: today))]
               }),
        Oracle(name: "StepsCounter.stepsInWindow",
               inputs: cases(40, seed: 17) { r in
                   var ts = 1_760_000_000, counter = r.int(0...65_535)
                   let classes = r.chance(0.5)
                   let rows: [[String: Any]] = (0..<r.int(0...80)).map { _ in
                       ts += r.int(1...120); counter = (counter + r.int(0...40)) & 0xFFFF
                       return ["ts": ts, "counter": counter, "cls": classes && r.chance(0.9) ? r.int(0...6) as Any : NSNull()]
                   }
                   return ["rows": rows]
               },
               run: { a in
                   nn(StepsCounter.stepsInWindow((a["rows"] as! [[String: Any]]).map {
                       StepSample(ts: $0["ts"] as! Int, counter: $0["counter"] as! Int, activityClass: $0["cls"] as? Int)
                   }))
               }),
        Oracle(name: "HRVReadiness.evaluate",
               inputs: cases(50, seed: 18) { r in
                   let base = r.double(20...120)
                   return ["hrv": (0..<r.int(0...40)).map { _ in r.chance(0.15) ? NSNull() as Any : base + r.double(-30...30) as Any }]
               },
               run: { a in
                   guard let res = HRVReadiness.evaluate(avgHrv: (a["hrv"] as! [Any]).map { $0 as? Double }) else { return NSNull() }
                   return ["tier": String(describing: res.tier), "baseline": res.baseline7Ms, "low": res.normalLowMs,
                           "high": res.normalHighMs]
               }),
        Oracle(name: "StepsEstimateEngine.estimate",
               inputs: cases(50, seed: 19) { r in
                   ["motion": r.double(-10...20_000), "coefficient": r.double(-1...3)]
               },
               run: { a in
                   nn(StepsEstimateEngine.estimate(motion: a["motion"] as! Double, calibration: .init(
                       coefficient: a["coefficient"] as! Double, sampleDays: 10, confidence: 0.5, manual: false)))
               }),
        Oracle(name: "SleepStageTotals.mainNightIndex",
               inputs: cases(50, seed: 20) { r in
                   var t = 1_760_000_000 + r.int(0...86_400)
                   let blocks: [[Int]] = (0..<r.int(0...6)).map { _ in
                       t += r.int(600...30_000); let start = t; t += r.int(600...36_000); return [start, t]
                   }
                   return ["blocks": blocks, "offset": [0, 3_600, -18_000, 32_400][r.int(0...3)],
                           "habitual": r.chance(0.5) ? NSNull() : r.int(0...86_399)]
               },
               run: { a in
                   nn(SleepStageTotals.mainNightIndex((a["blocks"] as! [[Int]]).map { .init(start: $0[0], end: $0[1]) },
                                                      offsetSec: a["offset"] as! Int, habitualMidsleepSec: a["habitual"] as? Int))
               }),
        Oracle(name: "RhythmScreener",
               inputs: cases(30, seed: 21) { r in
                   let windows: [[String: Any]] = (0..<r.int(1...8)).map { _ in
                       let base = r.double(600...1200), irregular = r.chance(0.3)
                       var ts = 1_760_000_000
                       let rr: [Double] = (0..<r.int(0...150)).map { _ in
                           irregular ? r.double(350...1600) : (r.chance(0.03) ? base * 0.6 : base + r.double(-40...40))
                       }
                       let stamps: [Int] = rr.map { v in ts += max(1, Int(v / 1000)); return ts }
                       return ["rr": rr, "ts": stamps, "still": r.chance(0.85), "hr": 60_000 / base,
                               "ppg": r.chance(0.3) ? rr.map { $0 + r.double(-15...15) } as Any : NSNull()]
                   }
                   return ["windows": windows]
               },
               run: { a in
                   let results = (a["windows"] as! [[String: Any]]).map {
                       RhythmScreener.screenWindow(.init(rrMs: $0["rr"] as! [Double], ts: $0["ts"] as! [Int],
                                                         ppgIBIms: $0["ppg"] as? [Double], motionStill: $0["still"] as! Bool,
                                                         meanHR: $0["hr"] as! Double))
                   }
                   let night = RhythmScreener.summarizeNight(results)
                   return ["windows": results.map { ["label": $0.label.rawValue, "sd1": nn($0.sd1), "sd2": nn($0.sd2),
                                                     "ratio": nn($0.sd1sd2), "norm": nn($0.normRmssd),
                                                     "tpr": nn($0.turningPointRate), "ectopic": nn($0.ectopicFraction),
                                                     "n": $0.nBeats, "confidence": $0.confidence.rawValue,
                                                     "agreed": $0.agreedAcrossSources] },
                           "readable": night.readableWindows, "steady": night.steadyWindows,
                           "occasional": night.occasionalWindows, "varied": night.variedWindows,
                           "recurred": night.variationRecurred, "overall": night.overall.rawValue]
               }),
        Oracle(name: "CoachSuggestions.suggestions",
               inputs: cases(60, seed: 22) { r in
                   let start = 20_400 + r.int(0...50)
                   return ["today": r.chance(0.1) ? NSNull() : dailyRow(&r, day: day(start + 30)),
                           "recent": (0..<r.int(0...30)).map { dailyRow(&r, day: day(start + $0)) }]
               },
               run: { a in
                   CoachSuggestions.suggestions(for: (a["today"] is NSNull) ? nil : dailyRows([a["today"]!]).first,
                                                recent: dailyRows(a["recent"]))
               }),
        Oracle(name: "EffectRanker.rank",
               inputs: cases(25, seed: 23) { r in
                   let start = 20_500, n = r.int(10...80)
                   let days = (0..<n).map { day(start + $0) }
                   var behaviors: [String: [String]] = [:], controls: [String: [String]] = [:]
                   for name in ["alcohol", "caffeine", "late meal", "stretching"].prefix(r.int(1...4)) {
                       behaviors[name] = days.filter { _ in r.chance(0.35) }
                       controls[name] = days.filter { d in !(behaviors[name]!.contains(d)) && r.chance(0.8) }
                   }
                   var outcome: [String: Double] = [:]
                   for d in days where r.chance(0.9) { outcome[d] = r.double(20...95) }
                   return ["behaviors": behaviors, "controls": controls, "outcome": outcome]
               },
               run: { a in
                   let toSets = { (any: Any?) in (any as! [String: [String]]).mapValues(Set.init) }
                   return EffectRanker.rank(behaviors: toSets(a["behaviors"]), controls: toSets(a["controls"]),
                                            outcomeByDay: a["outcome"] as! [String: Double], outcome: "charge").map {
                       ["behavior": $0.behavior, "lag": $0.lag, "delta": $0.effect.delta, "d": $0.effect.cohensD,
                        "p": $0.effect.pApprox, "n": $0.effect.nWith, "nWithout": $0.effect.nWithout,
                        "adjustedP": nn($0.adjustedP), "fdr": $0.fdrSignificant, "confidence": $0.confidence.rawValue]
                   }
               }),
        Oracle(name: "StrapComparison.compare",
               inputs: cases(40, seed: 24) { r in
                   func side() -> [String: Double] {
                       var m: [String: Double] = [:]
                       for k in ["restingHR", "heartRate", "hrv", "spo2", "skinTemp", "steps", "sleep", "calories"] where r.chance(0.6) {
                           m[k] = r.double(0...200)
                       }
                       return m
                   }
                   return ["a": side(), "b": side()]
               },
               run: { a in
                   func kinds(_ any: Any?) -> [MetricArbitrationPolicy.MetricKind: Double] {
                       Dictionary(uniqueKeysWithValues: (any as! [String: Double]).compactMap { k, v in
                           MetricArbitrationPolicy.MetricKind.allCases.first { "\($0)" == k }.map { ($0, v) }
                       })
                   }
                   return StrapComparison.compare(kinds(a["a"]), kinds(a["b"])).map {
                       ["metric": "\($0.metric)", "a": nn($0.a), "b": nn($0.b), "agreement": $0.agreement.rawValue]
                   }
               }),
        Oracle(name: "HypnogramCoverage.isHoled",
               inputs: cases(50, seed: 25) { r in
                   let from = 1_760_000_000, to = from + r.int(1_800...36_000)
                   return ["stages": r.chance(0.1) ? NSNull() : stagesJSON(&r, from: from, to: to) as Any,
                           "span": Double(to - from) * r.double(0.5...1.5)]
               },
               run: { a in HypnogramCoverage.isHoled(stagesJSON: a["stages"] as? String, spanSeconds: a["span"] as! Double) }),
        Oracle(name: "SleepWindowReclip.reclip",
               inputs: cases(50, seed: 26) { r in
                   let from = 1_760_000_000, to = from + r.int(3_600...36_000)
                   let newStart = from + r.int(-3_600...7_200), newEnd = to + r.int(-7_200...3_600)
                   return ["stages": stagesJSON(&r, from: from, to: to), "start": from, "oldEnd": to,
                           "newStart": newStart, "newEnd": max(newStart + 60, newEnd)]
               },
               run: { a in
                   nn(SleepWindowReclip.reclip(stagesJSON: a["stages"] as? String, sessionStart: a["start"] as! Int,
                                               oldEnd: a["oldEnd"] as! Int, newStart: a["newStart"] as! Int,
                                               newEnd: a["newEnd"] as! Int).map(CoreParityOracleTests.canonicalJSON))
               }),
        Oracle(name: "DaytimeBaselines",
               inputs: cases(10, seed: 27) { r in
                   let days: [[String: Any]] = (0..<r.int(0...16)).map { d in
                       let start = 1_760_000_000 - 1_760_000_000 % 86_400 + d * 86_400 + 7 * 3_600
                       let hrRows = hrSeries(&r, from: start, seconds: r.int(2...12) * 3_600, step: r.int(10...120), base: 72)
                       var ts = start, rr: [[Int]] = []
                       while ts < start + 6 * 3_600 { if r.chance(0.6) { rr.append([ts, r.int(650...1050)]) }; ts += r.int(1...8) }
                       return ["hr": hrRows, "rr": rr]
                   }
                   return ["days": days, "tz": [0, 3_600, -18_000][r.int(0...2)]]
               },
               run: { a in
                   let tz = a["tz"] as! Int
                   let aggregates = (a["days"] as! [[String: Any]]).map { d in
                       DaytimeStress.dayDaytimeAggregate(hr: hr(d["hr"]), rr: (d["rr"] as! [[Int]]).map { RRInterval(ts: $0[0], rrMs: $0[1]) },
                                                         tzOffsetSeconds: tz)
                   }
                   let mode: Any
                   switch DaytimeStress.scoringModeFromAggregates(aggregates) {
                   case .dayRelative: mode = "dayRelative"
                   case .baselineRelative(let h, let rm):
                       mode = ["hr": h.baseline, "hrSpread": h.spread, "rmssd": nn(rm?.baseline), "rmssdSpread": nn(rm?.spread)]
                   }
                   return ["aggregates": aggregates.map { ["hr": nn($0.hr), "rmssd": nn($0.rmssd)] }, "mode": mode]
               }),
        Oracle(name: "ActivityCostEngine.evaluate",
               inputs: cases(25, seed: 28) { r in
                   let start = 20_600, n = r.int(10...90)
                   var sports: [String: [String]] = [:]
                   for s in ["running", "cycling", "strength"].prefix(r.int(1...3)) {
                       sports[s] = (0..<n).filter { _ in r.chance(0.2) }.map { day(start + $0) }
                   }
                   var rec: [String: Double] = [:]
                   for d in 0..<n where r.chance(0.85) { rec[day(start + d)] = r.double(10...99) }
                   return ["sports": sports, "recovery": rec]
               },
               run: { a in
                   ActivityCostEngine.evaluate(activityDaysBySport: (a["sports"] as! [String: [String]]).mapValues(Set.init),
                                               recoveryByDay: a["recovery"] as! [String: Double]).map {
                       ["sport": $0.sport, "delta": $0.delta, "next": $0.meanNextMorning, "base": $0.baselineMean]
                   }
               }),
        Oracle(name: "SleepEdits",
               inputs: cases(60, seed: 29) { r in
                   let s1 = 1_760_000_000 + r.int(0...3_600), e1 = s1 + r.int(600...36_000)
                   let s2 = s1 + r.int(-20_000...20_000), e2 = s2 + r.int(600...36_000)
                   return ["a": [s1, e1, r.chance(0.3) ? s1 + r.int(0...1_200) : -1], "b": [s2, e2, -1],
                           "now": e1 + r.int(-7_200...7_200), "onset": s1 + r.int(-1_200...1_200)]
               },
               run: { a in
                   func session(_ v: [Int]) -> CachedSleepSession {
                       CachedSleepSession(startTs: v[0], endTs: v[1], efficiency: nil, restingHr: nil, avgHrv: nil,
                                          stagesJSON: nil, startTsAdjusted: v[2] < 0 ? nil : v[2])
                   }
                   let x = session(a["a"] as! [Int]), y = session(a["b"] as! [Int])
                   let w = SleepEditGuard.clampedEditWindow(start: x.startTs, end: x.endTs, now: a["now"] as! Int)
                   let g = SleepGroupEdit.groupWindow([x, y])
                   return ["duplicate": SleepSessionDedup.isDuplicate(x, y),
                           "keyed": nn(SleepSessionDedup.safeKeyedStart(onset: a["onset"] as! Int, mapped: x)),
                           "edit": nn(w.map { [$0.start, $0.end] }), "group": nn(g.map { [$0.start, $0.end] })]
               }),
    ]

    func testEveryOracleMatchesTheSwiftCode() throws {
        let write = ProcessInfo.processInfo.environment["NOOP_WRITE_PARITY"] == "1"
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        for oracle in Self.oracles {
            let url = Self.dir.appendingPathComponent("\(oracle.name).json")
            if write {
                let cases = oracle.inputs.map { ["input": $0, "output": oracle.run($0)] }
                let data = try JSONSerialization.data(withJSONObject: ["function": oracle.name, "cases": cases],
                                                      options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url)
                continue
            }
            let data = try Data(contentsOf: url)
            let file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let cases = try XCTUnwrap(file["cases"] as? [[String: Any]])
            XCTAssertEqual(cases.count, oracle.inputs.count, oracle.name)
            for (i, c) in cases.enumerated() {
                let input = try XCTUnwrap(c["input"] as? [String: Any])
                let expected = try JSONSerialization.data(withJSONObject: ["v": Self.nn(c["output"] ?? nil)], options: .sortedKeys)
                let actual = try JSONSerialization.data(withJSONObject: ["v": oracle.run(input)], options: .sortedKeys)
                XCTAssertEqual(String(decoding: actual, as: UTF8.self), String(decoding: expected, as: UTF8.self),
                               "\(oracle.name) case \(i): Swift no longer gives the committed answer")
            }
        }
    }
}
