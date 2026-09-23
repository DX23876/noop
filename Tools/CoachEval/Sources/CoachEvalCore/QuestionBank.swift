import Foundation
import CoachAnalysis

/// What a correct answer must contain.
public enum Expected: Equatable, Codable, Sendable {
    /// A number within `tolerance`. `signAgnostic` accepts "3 points lower" for −3.
    case number(Double, tolerance: Double, signAgnostic: Bool)
    case integer(Int)
    /// A `yyyy-MM-dd` day, accepted in the common written forms.
    case day(String)
}

/// One objective question about one synthetic wearer.
public struct EvalQuestion: Sendable {
    public let id: String
    public let template: String
    public let wearer: Int
    public let text: [String: String]
    public let expected: Expected
    /// A spec that answers it, used by the oracle check.
    public let oraclePlan: String
    public let oracleSpec: AnalysisSpec

    public func text(_ language: String) -> String { text[language] ?? text["en"]! }
}

/// The objective question set: nine templates over every wearer of the cohort. Answers come from
/// `Reference`, never from the executor.
public enum QuestionBank {

    struct Name { let en: String; let de: String }
    static let names: [String: Name] = [
        "hrv": .init(en: "HRV", de: "HRV"),
        "resting_hr": .init(en: "resting heart rate", de: "Ruhepuls"),
        "sleep_total_min": .init(en: "sleep duration in minutes", de: "Schlafdauer in Minuten"),
        "steps": .init(en: "daily steps", de: "täglichen Schritte"),
        "sleep_efficiency": .init(en: "sleep efficiency", de: "Schlafeffizienz"),
    ]

    /// Tolerance for a reported number. The tool prints whole numbers from 100, one decimal from 10 and two
    /// below; a model may round one step coarser above 1 (432.4 min as 432, 54.4 ms as 54, -4.43 % as -4.4
    /// but not -4) and must quote values below 1 as printed. Any looser and a result's other numbers —
    /// interval bounds, group means — start matching by coincidence, which the negative-control test measures.
    public static func tolerance(for value: Double) -> Double {
        let magnitude = abs(value)
        if magnitude >= 100 { return 1.0 }
        if magnitude >= 10 { return 0.5 }
        if magnitude >= 1 { return 0.051 }
        return 0.0051
    }

    public static func all(cohort: [SyntheticWearer] = SyntheticCohort.make()) -> [EvalQuestion] {
        cohort.flatMap(questions(for:))
    }

    /// How many questions of each family the smoke set takes. The comparisons carry the most weight: they
    /// are where alignment, tags and events can go wrong, so they get more questions than simple levels.
    static let smokeQuota: [String: Int] = [
        "mean": 4, "count": 3, "extreme": 3, "periods": 3, "alcohol": 4, "evening": 4, "weekend": 3,
        "trend": 3, "strain": 3,
    ]

    /// A fixed, stratified subset of 30 for fast iteration: each family spread over different wearers (and
    /// therefore different injected effect sizes), chosen by rule rather than by chance so it never changes.
    public static func smoke(from questions: [EvalQuestion]) -> [EvalQuestion] {
        let families = Dictionary(grouping: questions) { $0.template.split(separator: "-").first.map(String.init) ?? "" }
        var picked: [EvalQuestion] = []
        for (familyIndex, family) in families.keys.sorted().enumerated() {
            let members = families[family]!
            let wearers = Array(Set(members.map(\.wearer))).sorted()
            for k in 0..<(smokeQuota[family] ?? 0) where !wearers.isEmpty {
                let wearer = wearers[(familyIndex + 3 * k) % wearers.count]
                let pool = members.filter { $0.wearer == wearer }
                picked.append(pool[k % pool.count])
            }
        }
        return picked.sorted { $0.id < $1.id }
    }

    static func questions(for wearer: SyntheticWearer) -> [EvalQuestion] {
        let data = wearer.dataset
        var out: [EvalQuestion] = []
        func add(_ template: String, en: String, de: String, _ expected: Expected, plan: String, _ spec: AnalysisSpec) {
            out.append(EvalQuestion(id: "w\(wearer.id)-\(template)", template: template, wearer: wearer.id,
                                    text: ["en": en, "de": de], expected: expected,
                                    oraclePlan: plan, oracleSpec: spec))
        }

        // Level of a metric over a recent window.
        for metric in ["hrv", "resting_hr", "sleep_total_min", "steps"] {
            for days in [7, 30, 90] {
                let value = Reference.windowMean(data, metric, days: days)
                let n = names[metric]!
                add("mean-\(metric)-\(days)",
                    en: "What was my average \(n.en) over the last \(days) days?",
                    de: "Wie hoch war im Schnitt mein \(n.de) in den letzten \(days) Tagen?",
                    .number(value, tolerance: tolerance(for: value), signAgnostic: false),
                    plan: "Mean \(metric) over \(days) days",
                    AnalysisSpec(operation: .describe, windowDays: days, metric: .init(series: metric)))
            }
        }

        // Counting nights under a threshold.
        for (threshold, days) in [(85.0, 30), (80.0, 90)] {
            let count = Reference.countBelow(data, "sleep_efficiency", threshold: threshold, days: days)
            add("count-efficiency-\(Int(threshold))-\(days)",
                en: "On how many of the last \(days) nights was my sleep efficiency below \(Int(threshold)) %?",
                de: "In wie vielen der letzten \(days) Nächte lag meine Schlafeffizienz unter \(Int(threshold)) %?",
                .integer(count),
                plan: "Count nights with efficiency below \(Int(threshold))",
                AnalysisSpec(operation: .describe, windowDays: days, metric: .init(series: "sleep_efficiency"),
                             filter: .init(threshold: .init(series: "sleep_efficiency", lt: threshold))))
        }

        // Best and worst days.
        for metric in ["hrv", "sleep_total_min"] {
            for days in [30, 90] {
                for highest in [true, false] {
                    guard let day = Reference.extremeDay(data, metric, days: days, highest: highest) else { continue }
                    let n = names[metric]!
                    add("extreme-\(metric)-\(days)-\(highest ? "high" : "low")",
                        en: "Which day in the last \(days) days had my \(highest ? "highest" : "lowest") \(n.en)?",
                        de: "An welchem Tag der letzten \(days) Tage war mein \(n.de) am \(highest ? "höchsten" : "niedrigsten")?",
                        .day(day),
                        plan: "\(highest ? "Highest" : "Lowest") \(metric) day",
                        AnalysisSpec(operation: .rankDays, windowDays: days, metric: .init(series: metric),
                                     order: highest ? .highest : .lowest, limit: 1))
                }
            }
        }

        // The last 30 days against the 30 before.
        for metric in ["hrv", "resting_hr", "sleep_total_min"] {
            let diff = Reference.lastTwoMonthsDifference(data, metric)
            let n = names[metric]!
            add("periods-\(metric)",
                en: "By how much did my average \(n.en) change in the last 30 days compared with the 30 days before?",
                de: "Um wie viel hat sich mein durchschnittlicher \(n.de) in den letzten 30 Tagen gegenüber den 30 Tagen davor verändert?",
                .number(diff, tolerance: tolerance(for: diff), signAgnostic: true),
                plan: "Last 30 days vs the 30 before",
                AnalysisSpec(operation: .comparePeriods, windowDays: 60, metric: .init(series: metric),
                             periods: [.init(label: "last 30 days", fromDaysAgo: 29, toDaysAgo: 0),
                                       .init(label: "30 days before", fromDaysAgo: 59, toDaysAgo: 30)]))
        }

        // Alcohol and the next night's HRV.
        let alcohol = data.tags["alcohol"]!
        let alcoholDiff = Reference.nightAfterDifference(
            data, "hrv", days: 180,
            inA: { alcohol.yes.contains($0) },
            inB: { alcohol.answered.contains($0) && !alcohol.yes.contains($0) })
        add("alcohol-hrv",
            en: "Over the last 180 days, how different is my HRV the night after I drink alcohol compared with nights after I don't?",
            de: "Wie unterscheidet sich in den letzten 180 Tagen meine HRV in der Nacht nach Alkohol von Nächten ohne?",
            .number(alcoholDiff, tolerance: tolerance(for: alcoholDiff), signAgnostic: true),
            plan: "HRV the night after alcohol vs no alcohol",
            AnalysisSpec(operation: .compareGroups, windowDays: 180,
                         metric: .init(series: "hrv", align: .nightAfter),
                         groups: [.init(label: "alcohol", when: .init(tag: "alcohol")),
                                  .init(label: "no alcohol", when: .init(tag: "alcohol", tagValue: false))]))

        // Evening against morning workouts, and the night after.
        let eveningDiff = Reference.nightAfterDifference(
            data, "sleep_efficiency", days: 180,
            inA: { Reference.hasWorkout(data, on: $0) { $0 >= 18 } },
            inB: { Reference.hasWorkout(data, on: $0) { $0 < 12 } })
        add("evening-efficiency",
            en: "Over the last 180 days, how does my sleep efficiency after an evening workout (starting 6 pm or later) compare with after a morning workout (before noon)?",
            de: "Wie unterscheidet sich in den letzten 180 Tagen meine Schlafeffizienz nach einem Abendtraining (ab 18 Uhr) von der nach einem Morgentraining (vor 12 Uhr)?",
            .number(eveningDiff, tolerance: tolerance(for: eveningDiff), signAgnostic: true),
            plan: "Sleep efficiency after evening vs morning workouts",
            AnalysisSpec(operation: .compareGroups, windowDays: 180,
                         metric: .init(series: "sleep_efficiency", align: .nightAfter),
                         groups: [.init(label: "evening", when: .init(event: .init(kind: "workout", startHourGte: 18))),
                                  .init(label: "morning", when: .init(event: .init(kind: "workout", startHourLt: 12)))]))

        // Weekend nights.
        let weekendDiff = Reference.nightAfterDifference(
            data, "sleep_total_min", days: 180,
            inA: { [5, 6].contains(DayKey.isoWeekday(DayKey.ordinal($0)!)) },
            inB: { ![5, 6].contains(DayKey.isoWeekday(DayKey.ordinal($0)!)) })
        add("weekend-sleep",
            en: "Over the last 180 days, how much longer or shorter do I sleep on Friday and Saturday nights than on the other nights?",
            de: "Wie viel länger oder kürzer schlafe ich in den letzten 180 Tagen in den Nächten auf Samstag und Sonntag als in den übrigen Nächten?",
            .number(weekendDiff, tolerance: tolerance(for: weekendDiff), signAgnostic: true),
            plan: "Sleep after Friday and Saturday vs other days",
            AnalysisSpec(operation: .compareGroups, windowDays: 180,
                         metric: .init(series: "sleep_total_min", align: .nightAfter),
                         groups: [.init(label: "Fri/Sat nights", when: .init(weekdays: [5, 6])),
                                  .init(label: "other nights", when: .init(weekdays: [1, 2, 3, 4, 7]))]))

        // Trend.
        for days in [90, 180] {
            let slope = Reference.trendPer30(data, "resting_hr", days: days)
            add("trend-rhr-\(days)",
                en: "Over the last \(days) days, by how many bpm per 30 days has my resting heart rate been changing?",
                de: "Um wie viele Schläge pro Minute je 30 Tage hat sich mein Ruhepuls in den letzten \(days) Tagen verändert?",
                .number(slope, tolerance: tolerance(for: slope), signAgnostic: true),
                plan: "Resting HR trend",
                AnalysisSpec(operation: .trend, windowDays: days, metric: .init(series: "resting_hr")))
        }

        // Lagged association.
        let rho = Reference.spearmanNightAfter(data, day: "strain", night: "hrv", days: 180)
        add("strain-hrv-corr",
            en: "Over the last 180 days, what is the rank correlation between a day's strain and my HRV the following night?",
            de: "Wie hoch ist in den letzten 180 Tagen die Rangkorrelation zwischen der Belastung eines Tages und meiner HRV in der folgenden Nacht?",
            .number(rho, tolerance: tolerance(for: rho), signAgnostic: false),
            plan: "Strain vs next night's HRV",
            AnalysisSpec(operation: .correlate, windowDays: 180, metric: .init(series: "strain", align: .sameDay),
                         metric2: .init(series: "hrv", align: .nightAfter)))
        return out
    }
}
