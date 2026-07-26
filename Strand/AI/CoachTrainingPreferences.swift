import Foundation

/// Local, conservative evidence about when a user repeatedly rejects a kind of session. This is not a
/// recommendation engine and never changes a plan: it gives the coach a small, auditable hypothesis to
/// ask about instead of repeatedly suggesting the same thing.
struct CoachTrainingPreferences {
    private struct Group: Hashable {
        let sport: String
        let weekend: Bool
    }

    private struct Counts {
        var decided = 0
        var declinedOrSkipped = 0
    }

    /// Summarises repeated negative decisions in a bounded window. A pattern needs at least three
    /// comparable decisions and a two-thirds negative rate; isolated declines are normal feedback, not
    /// a preference to memorialise.
    static func report(proposals: [PlanProposal], days: Int, now: Date = Date()) -> String {
        let window = max(30, min(days, 365))
        let cutoff = Calendar.current.date(byAdding: .day, value: -(window - 1), to: now) ?? now
        let cutoffDay = dayKey(cutoff)
        let relevant = proposals.filter { $0.status.isDecided && $0.day >= cutoffDay && !$0.sport.isEmpty }
        guard relevant.count >= 3 else {
            return "Not enough local planning decisions to identify a training preference yet."
        }

        var bySportAndDayKind: [Group: Counts] = [:]
        var bySport: [String: Counts] = [:]
        var displaySport: [String: String] = [:]
        for proposal in relevant {
            let sport = proposal.sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !sport.isEmpty else { continue }
            displaySport[sport] = proposal.sport.trimmingCharacters(in: .whitespacesAndNewlines)
            let negative = proposal.status == .declined || proposal.status == .skipped
            let dayGroup = Group(sport: sport, weekend: isWeekend(proposal.day))
            bySportAndDayKind[dayGroup, default: Counts()].decided += 1
            if negative { bySportAndDayKind[dayGroup, default: Counts()].declinedOrSkipped += 1 }
            bySport[sport, default: Counts()].decided += 1
            if negative { bySport[sport, default: Counts()].declinedOrSkipped += 1 }
        }

        let minimumRate = 2.0 / 3.0
        var lines: [String] = []
        let weekendPatterns = bySportAndDayKind.compactMap { group, counts -> (Group, Counts)? in
            guard group.weekend, counts.decided >= 3,
                  Double(counts.declinedOrSkipped) / Double(counts.decided) >= minimumRate else { return nil }
            return (group, counts)
        }.sorted { $0.1.declinedOrSkipped > $1.1.declinedOrSkipped }

        for (group, counts) in weekendPatterns.prefix(2) {
            let sport = displaySport[group.sport] ?? group.sport
            lines.append("\(sport) at weekends: \(counts.declinedOrSkipped) of \(counts.decided) suggestions were declined or skipped.")
        }

        // A sport-wide pattern is useful when it was not already explained by weekends. It deliberately
        // excludes any sport already shown above, so the coach gets a diverse, short evidence bundle.
        let weekendSports = Set(weekendPatterns.map { $0.0.sport })
        let sportPatterns = bySport.compactMap { sport, counts -> (String, Counts)? in
            guard !weekendSports.contains(sport), counts.decided >= 3,
                  Double(counts.declinedOrSkipped) / Double(counts.decided) >= minimumRate else { return nil }
            return (sport, counts)
        }.sorted { $0.1.declinedOrSkipped > $1.1.declinedOrSkipped }
        for (sportKey, counts) in sportPatterns.prefix(max(0, 3 - lines.count)) {
            let sport = displaySport[sportKey] ?? sportKey
            lines.append("\(sport): \(counts.declinedOrSkipped) of \(counts.decided) suggestions were declined or skipped.")
        }

        guard !lines.isEmpty else {
            return "No repeated local training-preference pattern is strong enough to report yet."
        }
        return (["LOCAL TRAINING-PREFERENCE HYPOTHESES (last \(window) days):"]
                + lines.map { "  • \($0)" }
                + ["Use these as a reason to ask and adapt together; do not silently remove activities or change the plan."])
            .joined(separator: "\n")
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isWeekend(_ day: String) -> Bool {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return false
        }
        return calendar.isDateInWeekend(date)
    }
}
