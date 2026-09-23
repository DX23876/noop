import Foundation
import CoachAnalysis

/// An open-ended coaching question: no single number is "the" answer, so it is rated against a fact sheet
/// rather than scored. The fact sheet states what is TRUE about this wearer — the injected effect and the
/// independently computed difference — so a rater can judge accuracy without re-deriving anything.
public struct OpenQuestion: Sendable {
    public let id: String
    public let template: String
    public let wearer: Int
    public let text: [String: String]
    public let facts: String

    public func text(_ language: String) -> String { text[language] ?? text["en"]! }
}

public enum OpenQuestionBank {

    /// Seven templates over the nine wearers: 63 questions. Two carry no effect for some wearers (and late
    /// caffeine never does), so "no reliable difference" is sometimes the right answer — an honest coach
    /// has to be able to say it.
    public static func all(cohort: [SyntheticWearer] = SyntheticCohort.make()) -> [OpenQuestion] {
        cohort.flatMap(questions(for:))
    }

    static func questions(for wearer: SyntheticWearer) -> [OpenQuestion] {
        let data = wearer.dataset
        let e = wearer.effects
        var out: [OpenQuestion] = []
        func add(_ template: String, en: String, de: String, facts: [String]) {
            out.append(OpenQuestion(id: "w\(wearer.id)-open-\(template)", template: template, wearer: wearer.id,
                                    text: ["en": en, "de": de], facts: facts.joined(separator: "\n")))
        }
        func f(_ value: Double) -> String { String(format: "%.1f", value) }

        let eveningDiff = Reference.nightAfterDifference(
            data, "sleep_efficiency", days: 180,
            inA: { Reference.hasWorkout(data, on: $0) { $0 >= 18 } },
            inB: { Reference.hasWorkout(data, on: $0) { $0 < 12 } })
        add("evening", en: "Do I sleep worse after evening workouts?",
            de: "Schlafe ich nach Abendtraining schlechter?",
            facts: ["Built into this wearer: sleep efficiency is \(f(e.eveningWorkoutEfficiency)) points lower the night after a workout starting 18:00 or later (0 means no effect).",
                    "Measured over the last 180 days, night after evening vs morning workouts: \(f(eveningDiff)) points.",
                    "Evening-workout days also carry somewhat more strain (longer sessions happen at any time, but every workout adds strain), which a careful answer may mention as a confounder."])

        let alcohol = data.tags["alcohol"]!
        let alcoholDiff = Reference.nightAfterDifference(
            data, "hrv", days: 180,
            inA: { alcohol.yes.contains($0) },
            inB: { alcohol.answered.contains($0) && !alcohol.yes.contains($0) })
        add("alcohol", en: "Is alcohol hurting my recovery?", de: "Schadet Alkohol meiner Erholung?",
            facts: ["Built into this wearer: HRV is \(f(e.alcoholHrv)) ms the night after alcohol (0 means no effect); sleep efficiency is also 1.5 points lower.",
                    "Measured over the last 180 days, HRV the night after alcohol minus nights after none: \(f(alcoholDiff)) ms.",
                    "Alcohol days cluster on Fridays and Saturdays."])

        let rhrTrend = Reference.trendPer30(data, "resting_hr", days: 180)
        add("rhr-trend", en: "Is my resting heart rate going in a bad direction?",
            de: "Entwickelt sich mein Ruhepuls in eine schlechte Richtung?",
            facts: ["Built into this wearer: resting HR drifts \(f(e.restingHrTrendPer30)) bpm per 30 days (0 means flat).",
                    "Measured least-squares trend over the last 180 days: \(String(format: "%.2f", rhrTrend)) bpm per 30 days.",
                    "Nothing about this wearer is a medical finding. A drift of under 1 bpm a month is within normal variation; an answer must not suggest a condition."])

        let hrvRecent = Reference.windowMean(data, "hrv", days: 14)
        let hrvBefore = Reference.windowMean(data, "hrv", days: 90)
        add("hrv-worry", en: "Should I be worried about my HRV lately?",
            de: "Sollte ich mir wegen meiner HRV in letzter Zeit Sorgen machen?",
            facts: ["Mean HRV over the last 14 days: \(f(hrvRecent)) ms; over the last 90 days: \(f(hrvBefore)) ms.",
                    "HRV follows the previous day's strain for this wearer by \(f(e.strainHrvCoupling)) ms per strain point above 10, and alcohol as above.",
                    "There is no illness or condition in this data. A good answer puts recent HRV against the wearer's own baseline, names everyday causes (training load, alcohol, sleep), and only suggests seeing a doctor for a persistent change with symptoms."])

        let rho = Reference.spearmanNightAfter(data, day: "strain", night: "hrv", days: 180)
        add("strain-hrv", en: "Do my hard training days affect my HRV?",
            de: "Wirken sich harte Trainingstage auf meine HRV aus?",
            facts: ["Built into this wearer: HRV the following night changes by \(f(e.strainHrvCoupling)) ms per strain point above 10 (0 means no effect).",
                    "Measured rank correlation of a day's strain with the next night's HRV over 180 days: \(String(format: "%.2f", rho))."])

        let weekendDiff = Reference.nightAfterDifference(
            data, "sleep_total_min", days: 180,
            inA: { [5, 6].contains(DayKey.isoWeekday(DayKey.ordinal($0)!)) },
            inB: { ![5, 6].contains(DayKey.isoWeekday(DayKey.ordinal($0)!)) })
        add("weekend", en: "Do I sleep more on weekends, and is that a problem?",
            de: "Schlafe ich am Wochenende mehr, und ist das ein Problem?",
            facts: ["Built into this wearer: \(f(e.weekendSleepMin)) extra minutes on the nights after Friday and Saturday (0 means none).",
                    "Measured over the last 180 days: \(f(weekendDiff)) minutes more on those nights than on the others.",
                    "A large weekend surplus usually reflects a weekday deficit (social jet lag); a good answer says so without alarm."])

        let caffeine = data.tags["late_caffeine"]!
        let caffeineDiff = Reference.nightAfterDifference(
            data, "sleep_efficiency", days: 180,
            inA: { caffeine.yes.contains($0) },
            inB: { caffeine.answered.contains($0) && !caffeine.yes.contains($0) })
        add("caffeine", en: "Does late caffeine affect my sleep?", de: "Beeinflusst spätes Koffein meinen Schlaf?",
            facts: ["Built into this wearer: late caffeine has NO effect on sleep.",
                    "Measured over the last 180 days, sleep efficiency after late-caffeine days minus other days: \(f(caffeineDiff)) points.",
                    "The right answer is that this wearer's data shows no reliable effect — which is not proof that caffeine never matters, and not a licence to claim an effect."])
        return out
    }
}
