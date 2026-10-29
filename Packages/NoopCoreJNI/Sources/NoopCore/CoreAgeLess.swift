import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// AgeLess on Android (parity plan 2.3): the shared `HealthspanSnapshot` over the core's store, every week
/// priced by the shared engine with its pace, status line, next steps and measures already resolved, so the
/// Kotlin screen only lays them out.
enum CoreAgeLess {
    struct Output: Encodable {
        var weeks: [Week]
        var today: String
        var gapNights: Int?
        var gapMissingMask: Double?
    }
    struct Week: Encodable {
        var day: String
        var provisional: Bool
        var coveredDays: Int
        var age: Double
        var actualAge: Double
        var delta: Double
        var pace: Double?
        var paceClass: String?
        var projectedAge: Double?
        var narrative: String
        var helper: String?
        var lever: String?
        var levers: [Lever]
        /// What all levers together would change the age by, priced on the combined inputs (curves do not add up).
        var leversYears: Double?
        var domains: [Domain]
    }
    struct Lever: Encodable { var component: String; var current: Double; var next: Double; var years: Double }
    struct Domain: Encodable { var domain: String; var years: Double; var measures: [Measure] }
    struct Measure: Encodable {
        var component: String
        var value: Double?
        var years: Double?
        var target: Double?
        var low: Double
        var high: Double
        var position: Double?
        var targetPosition: Double?
        var trendRising: Bool?
        var trendBetter: Bool?
    }

    /// The core's computed AgeLess series, read as the Apple Repository reads them.
    struct Reader: HealthspanSeriesReading {
        let reader: StoreReader
        let now: Date
        func healthspanSeries(key: String, days: Int?) async -> [(day: String, value: Double)] {
            let to = StoreReader.localDayKey(now)
            let from = days.map { StoreReader.localDayKey(now.addingTimeInterval(-Double($0) * 86_400)) } ?? "0000-01-01"
            return await reader.exploreSeries(key: key, source: MetricResolver.whoopSource, from: from, to: to,
                                              dailyRows: [], suppressedSleepWakeDays: [])
        }
    }

    @MainActor
    static func snapshot(reader: StoreReader, age: Int, sex: String, now: Date = Date()) async -> Output {
        let source = Reader(reader: reader, now: now)
        let gap = await HealthspanSnapshot.gap(repo: source)
        let today = StoreReader.localDayKey(now)
        guard age > 0, let snapshot = await HealthspanSnapshot.load(repo: source, age: age,
                                                                   sex: sex == "female" ? .female : .male) else {
            return Output(weeks: [], today: today, gapNights: gap?.nights, gapMissingMask: gap?.missingMask)
        }
        return Output(weeks: snapshot.weeks.map(week), today: today, gapNights: gap?.nights, gapMissingMask: gap?.missingMask)
    }

    private static func week(_ w: HealthspanWeek) -> Week {
        let levers = w.levers
        var after = w.inputs
        for l in levers { after.set(l.component, l.newValue) }
        let leversYears = levers.isEmpty ? nil : HealthspanEngine.compute(after).map { $0.deltaYears - w.result.deltaYears }
        let narrative = HealthspanEngine.narrative(result: w.result, pace: w.pace, levers: levers)
        let recent = w.recentResult
        let domains = HealthspanDomain.allCases.map { d -> Domain in
            let measures = HealthspanEngine.Component.allCases.filter { $0.domain == d }.map { c -> Measure in
                let contribution = w.result.contributions.first { $0.component == c }
                let scale = HealthspanEngine.barScale(c, age: w.inputs.age, sex: w.inputs.sex)
                let value = w.inputs.value(c)
                var trend: HealthspanEngine.Trend?
                if let wc = contribution, let wv = wc.value,
                   let rc = recent?.contributions.first(where: { $0.component == c }), let rv = rc.value {
                    trend = HealthspanEngine.trend(windowValue: wv, recentValue: rv, windowYears: wc.years, recentYears: rc.years)
                }
                return Measure(component: c.rawValue, value: value,
                               years: contribution?.value == nil ? nil : contribution?.years,
                               target: contribution?.target, low: scale.range.lowerBound, high: scale.range.upperBound,
                               position: value.map(scale.position), targetPosition: contribution.map { scale.position($0.target) },
                               trendRising: trend?.rising, trendBetter: trend?.better)
            }
            return Domain(domain: d.rawValue, years: w.result.years(in: d), measures: measures)
        }
        return Week(day: w.day, provisional: w.isProvisional, coveredDays: w.coveredDays,
                    age: w.result.healthspanAge, actualAge: w.result.chronologicalAge, delta: w.result.deltaYears,
                    pace: w.pace, paceClass: w.pace.map { "\(HealthspanEngine.PaceClass(pace: $0))" },
                    projectedAge: w.pace.map { HealthspanEngine.projectedAge(currentAge: w.result.healthspanAge, pace: $0) },
                    narrative: "\(narrative.kind)", helper: narrative.helper?.rawValue, lever: narrative.lever?.rawValue,
                    levers: levers.map { Lever(component: $0.component.rawValue, current: $0.currentValue,
                                               next: $0.newValue, years: $0.years) },
                    leversYears: leversYears, domains: domains)
    }
}
