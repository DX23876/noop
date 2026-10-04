import Foundation
import StrandAnalytics

/// What the small goal surfaces show, decided once (plan §17f): Today's goals card, the home-screen goal
/// widget and its accessories all read this, each showing as much of it as it has room for.
///
/// Daily goals come first, always. Weekly and monthly goals appear only when there is something to do or
/// to celebrate; a goal that is on course mid-week, was reached on an earlier day, or can no longer be
/// reached stays on the goals page. Long-term goals appear when a decision is due, they are at risk, or
/// the wearer pinned them. Everything not shown is counted in one summary line.
struct GoalSpotlight {

    enum Reason: Int, Comparable {
        case behind, decision, close, closing, reachedToday, pinned
        static func < (a: Reason, b: Reason) -> Bool { a.rawValue < b.rawValue }
    }

    enum Row: Identifiable {
        case period(PeriodGoalSnapshot, Reason)
        case longTerm(GoalTrackingSnapshot, Reason)

        var id: String {
            switch self {
            case .period(let s, _): return "p-\(s.id)"
            case .longTerm(let s, _): return "l-\(s.id)"
            }
        }
        var reason: Reason {
            switch self {
            case .period(_, let r), .longTerm(_, let r): return r
            }
        }
    }

    /// Up to three measured daily goals drawn as rings, in a fixed order so a ring keeps its place.
    var rings: [GoalActionOccurrence] = []
    /// Every other daily goal: the ones done or not (a workout, a box to tick) and measured ones beyond
    /// the three rings. They are counted, not drawn, so ten daily goals read as well as two.
    var checks: [GoalActionOccurrence] = []
    /// All of today's daily goals, and how many are done.
    var dailyTotal = 0
    var dailyDone = 0

    static let maxRings = 3
    /// At most `maxRows` weekly, monthly or long-term goals that need a look today.
    var rows: [Row] = []
    /// "Week 2/3 on course · October 1/1 on course", or nil without weekly and monthly goals.
    var summary: String?

    static let maxRows = 2

    static func make(todayActions: [GoalActionOccurrence], periodSnapshots: [PeriodGoalSnapshot],
                     longTerm: [GoalTrackingSnapshot], pinnedLongTerm: Set<UUID>,
                     maxRows: Int = maxRows) -> GoalSpotlight {
        var spotlight = GoalSpotlight()
        // Rings: goals marked for one first, then the automatic ones, in the fixed order; three at most.
        let measured = todayActions.filter { $0.fraction != nil && $0.action.showsAsRing != false }
            .sorted { a, b in
                let pa = a.action.showsAsRing == true, pb = b.action.showsAsRing == true
                return pa != pb ? pa : ringOrder(a, b)
            }
        spotlight.rings = Array(measured.prefix(maxRings)).sorted(by: ringOrder)
        let ringIds = Set(spotlight.rings.map(\.id))
        spotlight.checks = todayActions.filter { !ringIds.contains($0.id) }.sorted(by: ringOrder)
        spotlight.dailyTotal = todayActions.count
        spotlight.dailyDone = todayActions.filter(\.isCompleted).count

        let open = periodSnapshots.filter { $0.goal.status == .active }
        var candidates: [Row] = []
        for s in open {
            if let reason = reason(for: s) { candidates.append(.period(s, reason)) }
        }
        for s in longTerm where s.goal.status == .active {
            if s.health == .atRisk { candidates.append(.longTerm(s, .behind)) }
            else if s.health == .decisionNeeded { candidates.append(.longTerm(s, .decision)) }
            else if pinnedLongTerm.contains(s.id) { candidates.append(.longTerm(s, .pinned)) }
        }
        // Most urgent first; weekly before monthly within the same urgency (it ends sooner).
        candidates.sort { a, b in
            if a.reason != b.reason { return a.reason < b.reason }
            return periodRank(a) < periodRank(b)
        }
        spotlight.rows = Array(candidates.prefix(maxRows))
        spotlight.summary = summaryLine(open)
        return spotlight
    }

    /// Why a weekly or monthly goal deserves a line today, or nil when it does not.
    static func reason(for s: PeriodGoalSnapshot) -> Reason? {
        switch s.state {
        case .behind: return .behind
        case .close: return .close
        case .achieved: return s.reachedToday ? .reachedToday : nil
        case .outOfReach, .protected, .noData, .starting: return nil
        case .onTrack, .ahead:
            // The end of a period is when an open goal needs its last push: the last two days of a
            // week, the last week of a month.
            let closing = s.goal.period == .week ? s.daysLeft <= 2 : s.daysLeft <= 7
            return closing && s.result.remaining > 0 ? .closing : nil
        }
    }

    private static func periodRank(_ row: Row) -> Int {
        switch row {
        case .period(let s, _): return s.goal.period == .week ? 0 : 1
        case .longTerm: return 2
        }
    }

    private static func ringOrder(_ a: GoalActionOccurrence, _ b: GoalActionOccurrence) -> Bool {
        func rank(_ o: GoalActionOccurrence) -> Int {
            switch o.action.requirement {
            case .steps: return 0
            case .activeCalories: return 1
            case .sleep: return 2
            case .workout: return 3
            case .manual: return 4
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.action.createdAt < b.action.createdAt
    }

    private static func summaryLine(_ open: [PeriodGoalSnapshot]) -> String? {
        func onCourse(_ items: [PeriodGoalSnapshot]) -> Int {
            items.filter { [.onTrack, .ahead, .achieved].contains($0.state) }.count
        }
        var parts: [String] = []
        let week = open.filter { $0.goal.period == .week }
        let month = open.filter { $0.goal.period == .month }
        if !week.isEmpty { parts.append(String(localized: "Week \(onCourse(week))/\(week.count) on course")) }
        if !month.isEmpty {
            let name = Date().formatted(.dateTime.month(.wide))
            parts.append(String(localized: "\(name) \(onCourse(month))/\(month.count) on course"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension PeriodGoalSnapshot {
    /// The goal was reached with today's contribution, not before: worth a line on the day it happens.
    var reachedToday: Bool {
        guard state == .achieved, todayIndex >= 0, todayIndex < dayValues.count else { return false }
        let today = dayValues[todayIndex] ?? 0
        switch goal.metric.aggregation {
        case .count, .sum: return today > 0 && result.current - today < result.target
        case .hitDays: return today > 0 && result.current - 1 < result.target
        case .average: return false
        }
    }
}
