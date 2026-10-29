import Foundation
import StrandAnalytics

/// What the goal notifications say and when (plan §17h, Q25), without delivering anything: a daily goal reached and
/// new badges in one notice, the evening reminder for a streak still doable or a box still open, and a long-term
/// milestone passed. Shared by Apple's `GoalEventNotifier`, which posts through UserNotifications, and the Android
/// core (parity plan 2.3), whose host posts through its own notification manager. Both keep `State` between runs.
///
/// The rules the wearer chose: at most two goal notifications a day, bundled when they fall together; never in the
/// quiet hours, never after 21:00, never during a workout; and while the app is open the ring's own moment says it
/// instead. What happened is marked as handled whether or not it is told, so nothing is sent hours later.
enum GoalEventPlan {
    enum Kind: String, CaseIterable, Codable { case reached, streak, badge, milestone }

    static let dailyLimit = 2
    /// Never later than this minute of the day (21:00).
    static let latestMinute = 21 * 60
    /// "Still doable" for a step streak in the evening: about 45 minutes of walking.
    static let doableSteps = 45 * 110

    /// Today's bookkeeping, replaced when the day changes, plus what was ever told.
    struct State: Codable, Equatable {
        var day = ""
        var sent = 0
        var reached: [String] = []
        var eveningSent = false
        var toldBadges: [String] = []
        var milestoneCounts: [String: Int] = [:]
        var milestoneRoutes: [String: String] = [:]
    }

    /// What the host knows at this moment.
    struct Context {
        var kinds: Set<Kind>
        var workoutInProgress = false
        var appIsActive = false
        /// Whether `now` falls in the wearer's quiet hours.
        var quiet = false
        /// The minute of the day the evening reminder may go from (`eveningMinute` on Apple).
        var eveningMinute = 19 * 60
        var seenBadgeIds: Set<String> = []
    }

    /// One notification to post. `tickGoalId` and `tickDay` let it tick the one open box; `evening` picks the
    /// category with "remind me in an hour".
    struct Message: Equatable {
        let id: String, title: String, body: String
        var tickGoalId: String?, tickDay: String?
        var evening = false
    }

    // MARK: - Daily

    static func daily(todayActions: [GoalActionOccurrence], motivation: GoalMotivationSnapshot?, state input: State,
                      context: Context, now: Date, calendar: Calendar) -> (Message?, State) {
        let day = GoalActionEvaluator.dayKey(now, calendar: calendar)
        var state = input
        if state.day != day {
            state.day = day; state.sent = 0; state.reached = []; state.eveningSent = false
        }
        let freshReached = todayActions.filter {
            $0.isCompleted && $0.fraction != nil && !state.reached.contains($0.action.id.uuidString)
        }
        state.reached += freshReached.map(\.action.id.uuidString)
        var told = Set(state.toldBadges)
        let freshBadges = (motivation?.earned ?? []).filter {
            !told.contains($0.id) && !context.seenBadgeIds.contains($0.id)
        }
        told.formUnion(freshBadges.map(\.id))
        state.toldBadges = told.sorted()

        guard !context.kinds.isEmpty, !context.workoutInProgress, !context.appIsActive else { return (nil, state) }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard minute < latestMinute, !context.quiet, state.sent < dailyLimit else { return (nil, state) }

        // Reached and new badges, in one notification.
        var title: String?
        var lines: [String] = []
        if context.kinds.contains(.reached), !freshReached.isEmpty {
            title = freshReached.count == 1 ? String(localized: "⭐ \(freshReached[0].action.title) reached")
                                            : String(localized: "⭐ \(freshReached.count) daily goals reached")
            for o in freshReached {
                if let streak = motivation?.streaks[o.action.id]?.current, streak >= 2 {
                    lines.append(String(localized: "\(o.action.title): day \(streak) in a row."))
                }
            }
        }
        if context.kinds.contains(.badge), !freshBadges.isEmpty {
            if title == nil {
                title = freshBadges.count == 1 ? String(localized: "New badge")
                                               : String(localized: "\(freshBadges.count) new badges")
            }
            lines.append(freshBadges.prefix(2).map(\.title).joined(separator: " · "))
        }
        if let title {
            let message = Message(id: "goal-event-\(day)-\(state.sent)", title: title, body: lines.joined(separator: " "))
            state.sent += 1
            return (message, state)
        }

        // Evening: a streak worth keeping that today has not met yet, while it is still doable.
        guard context.kinds.contains(.streak), !state.eveningSent, minute >= context.eveningMinute else {
            return (nil, state)
        }
        var text: String?
        for o in todayActions where !o.isCompleted {
            guard let streak = motivation?.streaks[o.action.id]?.current, streak >= 3,
                  let measured = o.measured, let target = o.measuredTarget else { continue }
            let left = target - measured
            switch o.action.requirement {
            case .steps where left > 0 && left <= Double(doableSteps):
                let steps = Int(left.rounded())
                text = String(localized: "\(steps.formatted()) steps to go for day \(streak + 1) in a row, about \(MomentumBuilder.walkMinutes(steps)) min of walking.")
            case .activeCalories where left > 0 && left <= 250:
                text = String(localized: "\(Int(left.rounded())) kcal to go for day \(streak + 1) in a row.")
            default:
                continue
            }
            break
        }
        // A box still to tick rides along; with exactly one, the notification can tick it.
        let openTicks = todayActions.filter { !$0.isCompleted && isTick($0.action.requirement) }
        guard text != nil || !openTicks.isEmpty else { return (nil, state) }
        var body = text ?? ""
        if !openTicks.isEmpty {
            let names = openTicks.prefix(2).map(\.action.title).joined(separator: ", ")
            body += (body.isEmpty ? "" : " ") + String(localized: "Still open: \(names).")
        }
        let tick = openTicks.count == 1 ? openTicks.first : nil
        let message = Message(id: "goal-evening-\(day)",
                              title: text != nil ? String(localized: "Keep your streak") : String(localized: "Still open today"),
                              body: body, tickGoalId: tick?.action.id.uuidString, tickDay: tick?.day, evening: true)
        state.eveningSent = true
        state.sent += 1
        return (message, state)
    }

    private static func isTick(_ requirement: GoalAction.Requirement) -> Bool {
        if case .manual = requirement { return true }
        return false
    }

    // MARK: - Long-term milestones

    /// A long-term goal passing a waypoint. Counted on every run and marked as seen whether or not it is told; the
    /// first count of a goal only records where it stands, so a goal that started past its first marks does not
    /// announce them.
    static func longTerm(_ snapshots: [GoalTrackingSnapshot], state input: State, context: Context, now: Date,
                         calendar: Calendar) -> (Message?, State) {
        var state = input
        var fresh: [String] = []
        var newMarks = 0
        for snapshot in snapshots where snapshot.goal.status == .active {
            guard let (window, metric) = milestones(snapshot.reading) else { continue }
            let key = snapshot.id.uuidString
            let step = MilestoneLedger.advance(high: state.milestoneCounts[key], storedRoute: state.milestoneRoutes[key],
                                               window: window)
            if step.fresh > 0 {
                newMarks += step.fresh
                fresh.append(String(localized: "\(snapshot.displayTitle): \(LongTermFormat.value(window.values[step.high - 1], metric))"))
            }
            state.milestoneCounts[key] = step.high
            state.milestoneRoutes[key] = MilestoneLedger.route(window)
        }
        guard !fresh.isEmpty, context.kinds.contains(.milestone), !context.workoutInProgress, !context.appIsActive
        else { return (nil, state) }
        let day = GoalActionEvaluator.dayKey(now, calendar: calendar)
        if state.day != day { state.day = day; state.sent = 0; state.reached = []; state.eveningSent = false }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard minute < latestMinute, !context.quiet, state.sent < dailyLimit else { return (nil, state) }
        let message = Message(id: "goal-milestone-\(day)-\(state.sent)",
                              title: newMarks == 1 ? String(localized: "Milestone reached")
                                                   : String(localized: "\(newMarks) milestones reached"),
                              body: fresh.prefix(2).joined(separator: " · "))
        state.sent += 1
        return (message, state)
    }

    private static func milestones(_ reading: GoalShapeReading?) -> (LongTermGoalMath.MilestoneWindow, LongTermMetric)? {
        switch reading {
        case .sum(let d)?: return d.milestones.map { ($0, d.metric) }
        case .target(let d)?: return d.milestones.map { ($0, d.metric) }
        case .best(let d)?: return d.milestones.map { ($0, .longestDistance) }
        default: return nil
        }
    }
}

// MARK: - Badges, in words (shared with the Android core)

extension GoalMotivation.Badge {
    var title: String {
        switch family {
        case .dailySteps: return String(localized: "\(threshold.formatted()) steps in a day")
        case .lifetimeSteps: return String(localized: "\(threshold.formatted()) steps in total")
        case .stepStreak: return String(localized: "\(threshold) days in a row")
        case .weeksReached:
            return threshold == 1 ? String(localized: "First weekly goal reached")
                                  : String(localized: "\(threshold) weekly goals reached")
        case .workouts: return String(localized: "\(threshold) workouts")
        }
    }

    /// The short figure on the medal. Some locales (German among them) do not abbreviate thousands, so
    /// from 100,000 on a figure the locale left whole is written with the SI "k": "500.000" did not fit.
    var shortValue: String {
        guard threshold >= 1_000 else { return "\(threshold)" }
        let compact = threshold.formatted(.number.notation(.compactName))
        guard threshold >= 100_000, !compact.contains(where: \.isLetter) else { return compact }
        return "\((threshold / 1_000).formatted())k"
    }
}

extension GoalMotivation.BadgeFamily {
    var title: String {
        switch self {
        case .dailySteps: return String(localized: "Steps in a day")
        case .lifetimeSteps: return String(localized: "Steps in total")
        case .stepStreak: return String(localized: "Step goal streaks")
        case .weeksReached: return String(localized: "Weekly goals reached")
        case .workouts: return String(localized: "Workouts")
        }
    }
}
