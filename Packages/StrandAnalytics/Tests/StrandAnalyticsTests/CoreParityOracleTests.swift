import Foundation
import XCTest
import WhoopProtocol
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
