import Foundation
import StrandAnalytics
import WhoopStore

/// Conservative, local journal→outcome analysis for Coach context.
///
/// A missing journal row is never placed in the "No" group. Each question is evaluated only on days
/// where that exact question has an explicit Yes or No answer. Three short lags are explored and the
/// reported p-value is Bonferroni-adjusted for every question×lag comparison in that window. These
/// safeguards make the result deliberately harder to surface than the exploratory Insights cards.
enum CoachJournalPatternAnalyzer {
    struct WindowEvidence: Equatable {
        let identifier: String
        let sentence: String
        let correctedP: Double
        let sampleCount: Int
    }

    private struct Candidate {
        let question: String
        let lag: Int
        let effect: BehaviorEffect
        let correctedP: Double
    }

    static func analyze(entries: [JournalEntry],
                        outcomeByDay: [String: Double],
                        outcomeName: String,
                        now: Date = Date()) -> [WindowEvidence] {
        let windows: [(String, Int?)] = [("28 days", 28), ("90 days", 90),
                                         ("365 days", 365), ("all available", nil)]
        return windows.compactMap { identifier, days in
            strongest(entries: entries,
                      outcomeByDay: outcomeByDay,
                      outcomeName: outcomeName,
                      identifier: identifier,
                      days: days,
                      now: now)
        }
    }

    private static func strongest(entries: [JournalEntry],
                                  outcomeByDay: [String: Double],
                                  outcomeName: String,
                                  identifier: String,
                                  days: Int?,
                                  now: Date) -> WindowEvidence? {
        let cutoffDay = days.flatMap {
            Calendar.current.date(byAdding: .day, value: -($0 - 1), to: now)
        }.map(dayKey)
        let relevant = entries.filter { entry in
            cutoffDay.map { entry.day >= $0 } ?? true
        }
        let byQuestion = Dictionary(grouping: relevant, by: \.question)
        let comparisonCount = max(1, byQuestion.count * EffectRanker.lagSet.count)
        var candidates: [Candidate] = []

        for question in byQuestion.keys.sorted() {
            guard let responses = byQuestion[question] else { continue }
            let explicit = Dictionary(responses.map { ($0.day, $0.answeredYes) },
                                      uniquingKeysWith: { _, latest in latest })
            let yesDays = Set(explicit.compactMap { $0.value ? $0.key : nil })
            let noDays = Set(explicit.compactMap { $0.value ? nil : $0.key })
            guard explicit.values.contains(true), explicit.values.contains(false) else { continue }

            for lag in EffectRanker.lagSet {
                var aligned: [String: Double] = [:]
                for day in explicit.keys {
                    guard let outcomeDay = shiftDay(day, by: lag),
                          let value = outcomeByDay[outcomeDay] else { continue }
                    aligned[day] = value
                }
                guard let effect = BehaviorInsights.effect(behaviorDays: yesDays,
                                                           controlDays: noDays,
                                                           outcomeByDay: aligned,
                                                           behavior: question,
                                                           outcome: outcomeName)
                else { continue }
                let corrected = min(1, effect.pApprox * Double(comparisonCount))
                let enough = min(effect.nWith, effect.nWithout)
                    >= BehaviorInsights.minGroupForSignificance
                guard enough, corrected < BehaviorInsights.alpha else { continue }
                candidates.append(Candidate(question: question,
                                            lag: lag,
                                            effect: effect,
                                            correctedP: corrected))
            }
        }

        guard let best = candidates.sorted(by: {
            if abs($0.effect.cohensD) != abs($1.effect.cohensD) {
                return abs($0.effect.cohensD) > abs($1.effect.cohensD)
            }
            if $0.lag != $1.lag { return $0.lag < $1.lag }
            return $0.question < $1.question
        }).first else { return nil }

        let n = best.effect.nWith + best.effect.nWithout
        let confidence = n >= 30 ? "higher personal evidence"
            : (n >= 16 ? "moderate personal evidence" : "limited personal evidence")
        let lagText = best.lag == 0 ? "same day"
            : (best.lag == 1 ? "next day" : "\(best.lag) days later")
        let base = BehaviorInsights.sentence(best.effect)
        let sentence = "\(identifier): \(base) Best alignment: \(lagText); \(confidence), "
            + "n=\(n), multiple-comparison-adjusted p≈\(String(format: "%.3f", best.correctedP)). "
            + "This is an association, not proof of causality."
        return WindowEvidence(identifier: identifier,
                              sentence: sentence,
                              correctedP: best.correctedP,
                              sampleCount: n)
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func shiftDay(_ day: String, by delta: Int) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day),
              let shifted = formatter.calendar.date(byAdding: .day, value: delta, to: date)
        else { return nil }
        return formatter.string(from: shifted)
    }
}
