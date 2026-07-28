import Foundation

/// Deterministic local guard between model suggestions and the plan book. It turns repeated feedback
/// into a concrete change even when the external model overlooks context: a short cool-down prevents
/// immediate re-pitches, repeated negative effects block the same activity until the coach asks, and
/// repeatedly helpful completion times become the default time for an otherwise untimed suggestion.
enum CoachRecommendationAdaptation {
    struct Advice: Equatable {
        let blockReason: String?
        let preferredTime: Date?
        let evidenceNote: String?
    }

    static func advice(sport: String,
                       intent: PlanProposal.Intent,
                       day: String,
                       proposedTime: Date?,
                       history: [PlanProposal],
                       now: Date = Date()) -> Advice {
        let sportKey = normalize(sport)
        let sameSport = history.filter { normalize($0.sport) == sportKey && $0.status.isDecided }
        let recentCutoff = now.addingTimeInterval(-14 * 86_400)
        let recentNegative = sameSport.filter {
            ($0.decidedAt ?? $0.createdAt) >= recentCutoff
                && ($0.status == .declined || $0.status == .skipped
                    || $0.effectFeedback == .negativeEffect)
        }

        if recentNegative.count >= 2, let latest = recentNegative.max(by: {
            ($0.decidedAt ?? $0.createdAt) < ($1.decidedAt ?? $1.createdAt)
        }), now.timeIntervalSince(latest.decidedAt ?? latest.createdAt) < 3 * 86_400 {
            return Advice(
                blockReason: "The user recently rejected, skipped, or felt worse after \(sport). "
                    + "Do not immediately re-pitch it; ask what should change or offer a different activity.",
                preferredTime: nil,
                evidenceNote: "Local 3-day feedback cool-down."
            )
        }

        let rated = sameSport.filter { $0.effectFeedback != nil }.prefix(5)
        let negativeEffects = rated.filter { $0.effectFeedback == .negativeEffect }.count
        if rated.count >= 3, negativeEffects * 3 >= rated.count * 2,
           intent == .moderate || intent == .hard {
            return Advice(
                blockReason: "\(negativeEffects) of the last \(rated.count) effect ratings for \(sport) "
                    + "said the user felt worse. Ask before proposing another moderate or hard version.",
                preferredTime: nil,
                evidenceNote: "Repeated negative effect feedback."
            )
        }

        if isWeekend(day) {
            let weekend = sameSport.filter { isWeekend($0.day) }.prefix(6)
            let rejected = weekend.filter { $0.status == .declined || $0.status == .skipped }.count
            if weekend.count >= 3, rejected * 3 >= weekend.count * 2 {
                return Advice(
                    blockReason: "\(rejected) of the last \(weekend.count) weekend \(sport) suggestions "
                        + "were declined or not completed. Ask about timing or offer a different form.",
                    preferredTime: nil,
                    evidenceNote: "Repeated weekend non-adherence."
                )
            }
        }

        guard proposedTime == nil else {
            return Advice(blockReason: nil, preferredTime: nil, evidenceNote: nil)
        }
        let helpfulTimes = sameSport.filter {
            $0.status == .completed && $0.effectFeedback == .helpful && $0.time != nil
        }.compactMap(\.time)
        guard helpfulTimes.count >= 2,
              let commonMinutes = modalMinutes(helpfulTimes),
              let preferred = date(day: day, minuteOfDay: commonMinutes)
        else {
            return Advice(blockReason: nil, preferredTime: nil, evidenceNote: nil)
        }
        return Advice(
            blockReason: nil,
            preferredTime: preferred,
            evidenceNote: "Used the most common time among \(helpfulTimes.count) helpful completions."
        )
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func modalMinutes(_ dates: [Date]) -> Int? {
        var counts: [Int: Int] = [:]
        for date in dates {
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            guard let hour = components.hour, let minute = components.minute else { continue }
            // Fifteen-minute buckets avoid treating 07:59 and 08:01 as unrelated habits.
            let bucket = ((hour * 60 + minute + 7) / 15) * 15
            counts[bucket, default: 0] += 1
        }
        return counts.max {
            $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
        }?.key
    }

    private static func date(day: String, minuteOfDay: Int) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let base = formatter.date(from: day) else { return nil }
        return Calendar.current.date(byAdding: .minute, value: minuteOfDay, to: base)
    }

    private static func isWeekend(_ day: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else { return false }
        return Calendar.current.isDateInWeekend(date)
    }
}
