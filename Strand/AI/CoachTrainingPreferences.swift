import Foundation

/// Local, conservative evidence about when a user repeatedly rejects a kind of session. This is not a
/// recommendation engine and never changes a plan: it gives the coach a small, auditable hypothesis to
/// ask about instead of repeatedly suggesting the same thing.
struct CoachTrainingPreferences {
    struct WindowReport: Equatable {
        let identifier: String
        let days: Int?
        let text: String
        let hasHypothesis: Bool
    }

    private struct Group: Hashable {
        let sport: String
        let weekend: Bool
    }

    private struct WeekdayGroup: Hashable {
        let sport: String
        let weekday: Int
    }

    private struct SeasonGroup: Hashable {
        let sport: String
        let season: String
    }

    private struct Counts {
        var decided = 0
        var declinedOrSkipped = 0
        var helpful = 0
        var noEffect = 0
        var negativeEffect = 0

        var feedbackTotal: Int { helpful + noEffect + negativeEffect }
    }

    /// Summarises repeated negative decisions in a bounded window. A pattern needs at least three
    /// comparable decisions and a two-thirds negative rate; isolated declines are normal feedback, not
    /// a preference to memorialise.
    static func report(proposals: [PlanProposal], days: Int, now: Date = Date()) -> String {
        let window = max(28, min(days, 3_650))
        return report(proposals: proposals, windowDays: window, label: "last \(window) days", now: now).text
    }

    /// The four durable windows used by the coach. The final window is the complete locally retained
    /// history, rather than another arbitrary cut-off. Empty windows are retained in the coach report
    /// so data gaps remain visible, but only `hasHypothesis` reports are written to semantic memory.
    static func longitudinalReports(proposals: [PlanProposal], now: Date = Date()) -> [WindowReport] {
        var reports = [28, 90, 365].map {
            report(proposals: proposals, windowDays: $0, label: "last \($0) days", now: now)
        }
        let oldest = proposals.compactMap { dayDate($0.day) }.min()
        let allDays = oldest.map {
            max(1, (Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0) + 1)
        } ?? 1
        reports.append(report(proposals: proposals,
                              windowDays: allDays,
                              label: "all available history",
                              identifier: "all",
                              now: now))
        return reports
    }

    static func longitudinalReport(proposals: [PlanProposal], now: Date = Date()) -> String {
        let reports = longitudinalReports(proposals: proposals, now: now)
        return (["LONG-TERM LOCAL HABIT MODEL:",
                 "Windows are evaluated separately so recent changes are not hidden by older history."]
                + reports.map(\.text)
                + [trendSummary(reports)]
                + ["These are observational personal hypotheses, not causal findings. Missing entries remain missing; they are never counted as rejection, non-completion, or no effect."])
            .joined(separator: "\n\n")
    }

    private static func report(proposals: [PlanProposal],
                               windowDays: Int,
                               label: String,
                               identifier: String? = nil,
                               now: Date) -> WindowReport {
        let window = max(1, windowDays)
        let cutoff = Calendar.current.date(byAdding: .day, value: -(window - 1), to: now) ?? now
        let cutoffDay = dayKey(cutoff)
        let relevant = proposals.filter { $0.status.isDecided && $0.day >= cutoffDay && !$0.sport.isEmpty }
        guard relevant.count >= 3 else {
            return WindowReport(identifier: identifier ?? "\(window)",
                                days: identifier == "all" ? nil : window,
                                text: "\(label): not enough recorded decisions yet (n=\(relevant.count)).",
                                hasHypothesis: false)
        }

        var bySportAndDayKind: [Group: Counts] = [:]
        var bySportAndWeekday: [WeekdayGroup: Counts] = [:]
        var bySportAndSeason: [SeasonGroup: Counts] = [:]
        var bySport: [String: Counts] = [:]
        var displaySport: [String: String] = [:]
        for proposal in relevant {
            let sport = proposal.sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !sport.isEmpty else { continue }
            displaySport[sport] = proposal.sport.trimmingCharacters(in: .whitespacesAndNewlines)
            let negative = proposal.status == .declined || proposal.status == .skipped
            let dayGroup = Group(sport: sport, weekend: isWeekend(proposal.day))
            let weekdayGroup = weekday(proposal.day).map {
                WeekdayGroup(sport: sport, weekday: $0)
            }
            let seasonGroup = season(proposal.day).map {
                SeasonGroup(sport: sport, season: $0)
            }
            bySportAndDayKind[dayGroup, default: Counts()].decided += 1
            if negative { bySportAndDayKind[dayGroup, default: Counts()].declinedOrSkipped += 1 }
            if let weekdayGroup {
                bySportAndWeekday[weekdayGroup, default: Counts()].decided += 1
                if negative {
                    bySportAndWeekday[weekdayGroup, default: Counts()].declinedOrSkipped += 1
                }
            }
            if let seasonGroup {
                bySportAndSeason[seasonGroup, default: Counts()].decided += 1
                if negative {
                    bySportAndSeason[seasonGroup, default: Counts()].declinedOrSkipped += 1
                }
            }
            bySport[sport, default: Counts()].decided += 1
            if negative { bySport[sport, default: Counts()].declinedOrSkipped += 1 }
            if let feedback = proposal.effectFeedback {
                switch feedback {
                case .helpful:
                    bySportAndDayKind[dayGroup, default: Counts()].helpful += 1
                    bySport[sport, default: Counts()].helpful += 1
                case .noEffect:
                    bySportAndDayKind[dayGroup, default: Counts()].noEffect += 1
                    bySport[sport, default: Counts()].noEffect += 1
                case .negativeEffect:
                    bySportAndDayKind[dayGroup, default: Counts()].negativeEffect += 1
                    bySport[sport, default: Counts()].negativeEffect += 1
                }
            }
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
            lines.append("\(sport) at weekends: \(counts.declinedOrSkipped) of \(counts.decided) suggestions were declined or not completed (\(certainty(counts.decided)) evidence).")
        }

        let dayPatternSports = Set(weekendPatterns.map { $0.0.sport })
        let weekdayPatterns = bySportAndWeekday.compactMap { group, counts -> (WeekdayGroup, Counts)? in
            guard !dayPatternSports.contains(group.sport),
                  counts.decided >= 3,
                  Double(counts.declinedOrSkipped) / Double(counts.decided) >= minimumRate
            else { return nil }
            return (group, counts)
        }.sorted { $0.1.declinedOrSkipped > $1.1.declinedOrSkipped }
        for (group, counts) in weekdayPatterns.prefix(max(0, 3 - lines.count)) {
            let sport = displaySport[group.sport] ?? group.sport
            lines.append("\(sport) on \(weekdayName(group.weekday))s: \(counts.declinedOrSkipped) of \(counts.decided) suggestions were declined or not completed (\(certainty(counts.decided)) evidence).")
        }

        // Seasonal patterns need a long enough observation window. Seasons are broad on purpose:
        // month-level slices would overfit sparse personal data.
        let seasonalPatterns: [(SeasonGroup, Counts)] = window >= 180
            ? bySportAndSeason.compactMap { group, counts in
                guard counts.decided >= 3,
                      Double(counts.declinedOrSkipped) / Double(counts.decided) >= minimumRate
                else { return nil }
                return (group, counts)
            }.sorted { $0.1.declinedOrSkipped > $1.1.declinedOrSkipped }
            : []
        let specificSports = dayPatternSports
            .union(weekdayPatterns.map { $0.0.sport })
            .union(seasonalPatterns.map { $0.0.sport })
        for (group, counts) in seasonalPatterns.prefix(max(0, 4 - lines.count)) {
            let sport = displaySport[group.sport] ?? group.sport
            lines.append("\(sport) in \(group.season): \(counts.declinedOrSkipped) of \(counts.decided) suggestions were declined or not completed (\(certainty(counts.decided)) evidence; seasonal hypothesis).")
        }

        // A sport-wide pattern is useful when it was not already explained by weekends. It deliberately
        // excludes any sport already shown above, so the coach gets a diverse, short evidence bundle.
        let sportPatterns = bySport.compactMap { sport, counts -> (String, Counts)? in
            guard !specificSports.contains(sport), counts.decided >= 3,
                  Double(counts.declinedOrSkipped) / Double(counts.decided) >= minimumRate else { return nil }
            return (sport, counts)
        }.sorted { $0.1.declinedOrSkipped > $1.1.declinedOrSkipped }
        for (sportKey, counts) in sportPatterns.prefix(max(0, 3 - lines.count)) {
            let sport = displaySport[sportKey] ?? sportKey
            lines.append("\(sport): \(counts.declinedOrSkipped) of \(counts.decided) suggestions were declined or not completed (\(certainty(counts.decided)) evidence).")
        }

        let effectPatterns = bySport.compactMap { sport, counts -> (String, Counts, Bool)? in
            guard counts.feedbackTotal >= 3 else { return nil }
            let helpfulRate = Double(counts.helpful) / Double(counts.feedbackTotal)
            let negativeRate = Double(counts.negativeEffect) / Double(counts.feedbackTotal)
            guard helpfulRate >= minimumRate || negativeRate >= minimumRate else { return nil }
            return (sport, counts, helpfulRate >= minimumRate)
        }.sorted { $0.1.feedbackTotal > $1.1.feedbackTotal }
        for (sportKey, counts, helpful) in effectPatterns.prefix(max(0, 4 - lines.count)) {
            let sport = displaySport[sportKey] ?? sportKey
            if helpful {
                lines.append("\(sport) was reported helpful after \(counts.helpful) of \(counts.feedbackTotal) completed recommendations (\(certainty(counts.feedbackTotal)) evidence).")
            } else {
                lines.append("\(sport) was followed by feeling worse after \(counts.negativeEffect) of \(counts.feedbackTotal) completed recommendations (\(certainty(counts.feedbackTotal)) evidence).")
            }
        }

        guard !lines.isEmpty else {
            return WindowReport(identifier: identifier ?? "\(window)",
                                days: identifier == "all" ? nil : window,
                                text: "\(label): no repeated pattern is strong enough yet (n=\(relevant.count); missing feedback is not interpreted).",
                                hasHypothesis: false)
        }
        let text = (["LOCAL HABIT HYPOTHESES (\(label), n=\(relevant.count)):"]
                    + lines.map { "  • \($0)" }
                    + ["Use these as a reason to ask and adapt together. They are observational and do not establish causality."])
            .joined(separator: "\n")
        return WindowReport(identifier: identifier ?? "\(window)",
                            days: identifier == "all" ? nil : window,
                            text: text,
                            hasHypothesis: true)
    }

    private static func certainty(_ count: Int) -> String {
        if count >= 12 { return "higher personal" }
        if count >= 6 { return "moderate personal" }
        return "limited personal"
    }

    private static func trendSummary(_ reports: [WindowReport]) -> String {
        guard let recent = reports.first(where: { $0.identifier == "28" }),
              let annual = reports.first(where: { $0.identifier == "365" }),
              let all = reports.first(where: { $0.identifier == "all" })
        else { return "Trend classification is unavailable because one or more windows are missing." }

        if recent.hasHypothesis && annual.hasHypothesis {
            return "Trend classification: a pattern is visible both recently and across the year; treat it as a persistent personal hypothesis."
        }
        if recent.hasHypothesis {
            return "Trend classification: a pattern is visible only in the recent window; treat it as emerging and re-check it before adapting strongly."
        }
        if annual.hasHypothesis || all.hasHypothesis {
            return "Trend classification: an older pattern exists but is not currently repeated strongly; treat it as historical, not a current preference."
        }
        return "Trend classification: no window currently contains a repeated pattern strong enough to classify."
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isWeekend(_ day: String) -> Bool {
        guard let date = dayDate(day) else { return false }
        return calendar.isDateInWeekend(date)
    }

    private static func weekday(_ day: String) -> Int? {
        dayDate(day).map { calendar.component(.weekday, from: $0) }
    }

    private static func weekdayName(_ weekday: Int) -> String {
        let names = calendar.weekdaySymbols
        guard names.indices.contains(weekday - 1) else { return "unknown weekday" }
        return names[weekday - 1]
    }

    private static func season(_ day: String) -> String? {
        guard let date = dayDate(day) else { return nil }
        switch calendar.component(.month, from: date) {
        case 12, 1, 2: return "winter"
        case 3, 4, 5: return "spring"
        case 6, 7, 8: return "summer"
        case 9, 10, 11: return "autumn"
        default: return nil
        }
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        return calendar
    }

    private static func dayDate(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
