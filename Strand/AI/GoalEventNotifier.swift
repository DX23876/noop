import Foundation
import UserNotifications
import StrandAnalytics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Notifications for daily goals (plan §17h): a goal reached, a streak in danger in the evening, a new
/// badge. Evaluated after every goals refresh, which also runs after each strap sync in the background,
/// so a ring closed on a walk is noticed without opening the app.
///
/// The rules the wearer chose: nothing until they agreed once (asked when the first ring closes); at most
/// two goal notifications a day, bundled when they fall together; never in the quiet hours, never after
/// 21:00, never during a workout; and while the app is open the ring's own moment says it instead.
@MainActor
enum GoalEventNotifier {

    enum Kind: String, CaseIterable, Identifiable {
        case reached, streak, badge, milestone
        var id: String { rawValue }
        var label: String {
            switch self {
            case .reached: return String(localized: "A daily goal reached")
            case .streak:  return String(localized: "A streak in danger, in the evening")
            case .badge:   return String(localized: "A new badge")
            case .milestone: return String(localized: "A long-term milestone reached")
            }
        }
    }

    static let consentAskedKey = "goals.notify.consentAsked"
    /// Reached and badge notices: no buttons, a tap opens the goals page.
    static let category = "noop.goal.event"
    /// The evening reminder: "remind me in an hour", plus "tick off" when exactly one box is open.
    static let eveningCategory = "noop.goal.evening"
    static let eveningTickCategory = "noop.goal.evening.tick"
    static let tickAction = "noop.goal.tick"
    static let snoozeAction = "noop.goal.snooze"
    static let dailyLimit = 2
    /// Never later than this minute of the day (21:00).
    static let latestMinute = 21 * 60
    /// "Still doable" for a step streak in the evening: about 45 minutes of walking.
    static let doableSteps = 45 * 110

    /// Set by the workout surfaces while a session runs; a goal notification never interrupts one.
    static var workoutInProgress = false

    static func isOn(_ kind: Kind) -> Bool {
        UserDefaults.standard.bool(forKey: "goals.notify.\(kind.rawValue)")
    }

    static func setOn(_ kind: Kind, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "goals.notify.\(kind.rawValue)")
    }

    /// The one question, asked when the first ring closes: yes turns the three kinds on.
    static var shouldAsk: Bool {
        !UserDefaults.standard.bool(forKey: consentAskedKey) && !Kind.allCases.contains(where: isOn)
    }

    static func answer(_ yes: Bool) {
        UserDefaults.standard.set(true, forKey: consentAskedKey)
        guard yes else { return }
        for kind in Kind.allCases { setOn(kind, true) }
        GoalNotifier.requestAuthorization()
    }

    /// Adds the goal category (tick off, remind in an hour) to the ones already registered, instead of
    /// replacing them.
    static func registerCategory() {
        let tick = UNNotificationAction(identifier: tickAction, title: String(localized: "Tick off"), options: [])
        let snooze = UNNotificationAction(identifier: snoozeAction, title: String(localized: "Remind me in 1 hour"),
                                          options: [])
        let ours: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: category, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: eveningCategory, actions: [snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: eveningTickCategory, actions: [tick, snooze], intentIdentifiers: [],
                                   options: []),
        ]
        // After a restore the choice comes back with the backup, the system permission does not: ask again.
        if Kind.allCases.contains(where: isOn) { GoalNotifier.requestAuthorization() }
        let ids = Set(ours.map(\.identifier))
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            center.setNotificationCategories(existing.filter { !ids.contains($0.identifier) }.union(ours))
        }
    }

    // MARK: - Evaluation

    /// Today's bookkeeping in one record, replaced when the day changes: how many went out, which goals
    /// were already told, whether the evening reminder went.
    private struct DayState: Codable {
        var day: String
        var sent = 0
        var reached: [String] = []
        var eveningSent = false
    }

    private static let dayStateKey = "goals.notify.day"
    private static let toldBadgesKey = "goals.notify.toldBadges"

    private static func dayState(_ day: String) -> DayState {
        guard let data = UserDefaults.standard.data(forKey: dayStateKey),
              let state = try? JSONDecoder().decode(DayState.self, from: data), state.day == day
        else { return DayState(day: day) }
        return state
    }

    private static func save(_ state: DayState) {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: dayStateKey) }
    }

    static func evaluate(todayActions: [GoalActionOccurrence], motivation: GoalMotivationSnapshot?,
                         now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        let day = GoalActionEvaluator.dayKey(now, calendar: calendar)
        var state = dayState(day)

        // What happened since the last look, marked as handled whether or not it is told: an event seen
        // in the open app, in the quiet hours or past the daily limit is never sent hours later.
        let freshReached = todayActions.filter {
            $0.isCompleted && $0.fraction != nil && !state.reached.contains($0.action.id.uuidString)
        }
        state.reached += freshReached.map(\.action.id.uuidString)
        var toldBadges = Set(UserDefaults.standard.stringArray(forKey: toldBadgesKey) ?? [])
        let freshBadges = (motivation?.earned ?? []).filter {
            !toldBadges.contains($0.id) && !GoalPrefs.seenBadgeIds.contains($0.id)
        }
        toldBadges.formUnion(freshBadges.map(\.id))
        UserDefaults.standard.set(Array(toldBadges), forKey: toldBadgesKey)
        defer { save(state) }

        guard Kind.allCases.contains(where: isOn), !workoutInProgress, !appIsActive else { return }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard minute < latestMinute, !GoalNotifier.isQuiet(now, calendar: calendar), state.sent < dailyLimit
        else { return }

        // Reached and new badges, in one notification.
        var title: String?
        var lines: [String] = []
        if isOn(.reached), !freshReached.isEmpty {
            title = freshReached.count == 1 ? String(localized: "⭐ \(freshReached[0].action.title) reached")
                                            : String(localized: "⭐ \(freshReached.count) daily goals reached")
            for o in freshReached {
                if let streak = motivation?.streaks[o.action.id]?.current, streak >= 2 {
                    lines.append(String(localized: "\(o.action.title): day \(streak) in a row."))
                }
            }
        }
        if isOn(.badge), !freshBadges.isEmpty {
            if title == nil {
                title = freshBadges.count == 1 ? String(localized: "New badge")
                                               : String(localized: "\(freshBadges.count) new badges")
            }
            lines.append(freshBadges.prefix(2).map(\.title).joined(separator: " · "))
        }
        if let title {
            post(id: "goal-event-\(day)-\(state.sent)", title: title, body: lines.joined(separator: " "), tickGoal: nil)
            state.sent += 1
            return
        }

        // Evening: a streak worth keeping that today has not met yet, while it is still doable.
        guard isOn(.streak), !state.eveningSent, minute >= eveningMinute(now: now, calendar: calendar) else { return }
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
        guard text != nil || !openTicks.isEmpty else { return }
        var body = text ?? ""
        if !openTicks.isEmpty {
            let names = openTicks.prefix(2).map(\.action.title).joined(separator: ", ")
            body += (body.isEmpty ? "" : " ") + String(localized: "Still open: \(names).")
        }
        post(id: "goal-evening-\(day)",
             title: text != nil ? String(localized: "Keep your streak") : String(localized: "Still open today"),
             body: body, tickGoal: openTicks.count == 1 ? openTicks.first : nil, evening: true)
        state.eveningSent = true
        state.sent += 1
    }

    private static func isTick(_ requirement: GoalAction.Requirement) -> Bool {
        if case .manual = requirement { return true }
        return false
    }

    /// Three hours before the usual bedtime (wake time minus sleep need, from the wind-down settings),
    /// 19:00 when that lands oddly, never past the 21:00 cut-off.
    static func eveningMinute(now: Date, calendar: Calendar) -> Int {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let weekday = calendar.component(.weekday, from: tomorrow)
        let bedtime = WindDownNudge.wakeMinutes(forWeekday: weekday) - WindDownNudge.sleepNeedMinutes + 24 * 60
        let reminder = bedtime - 180
        guard (16 * 60)...(latestMinute - 15) ~= reminder else { return 19 * 60 }
        return reminder
    }

    // MARK: - Actions

    /// A tap on an action of a goal notification.
    static func handle(actionIdentifier: String, userInfo: [AnyHashable: Any], content: UNNotificationContent) {
        switch actionIdentifier {
        case tickAction:
            guard let raw = userInfo["goalId"] as? String, let id = UUID(uuidString: raw),
                  let day = userInfo["day"] as? String else { return }
            GoalActionStore.shared.toggleManual(id, day: day)
        case snoozeAction:
            let again = content.mutableCopy() as? UNMutableNotificationContent ?? UNMutableNotificationContent()
            let fire = Date().addingTimeInterval(3_600)
            let minute = Calendar.autoupdatingCurrent.component(.hour, from: fire) * 60
                + Calendar.autoupdatingCurrent.component(.minute, from: fire)
            guard minute < latestMinute, !GoalNotifier.isQuiet(fire) else { return }
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "goal-snoozed-\(Int(fire.timeIntervalSince1970))", content: again,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3_600, repeats: false)))
        default:
            break
        }
    }

    // MARK: - Plumbing

    private static var appIsActive: Bool {
        #if canImport(UIKit) && !os(watchOS)
        return UIApplication.shared.applicationState == .active
        #elseif canImport(AppKit)
        return NSApplication.shared.isActive
        #else
        return false
        #endif
    }

    private static let milestoneCountsKey = "goals.notify.milestones"

    /// A long-term goal passing a waypoint (plan Q25). Counted on every refresh and marked as seen
    /// whether or not it is told, like the daily events; the first count of a goal only records where
    /// it stands, so a goal that started past its first marks does not announce them.
    static func evaluateLongTerm(_ snapshots: [GoalTrackingSnapshot], now: Date = Date(),
                                 calendar: Calendar = .autoupdatingCurrent) {
        var counts = (UserDefaults.standard.dictionary(forKey: milestoneCountsKey) as? [String: Int]) ?? [:]
        var fresh: [String] = []
        for snapshot in snapshots where snapshot.goal.status == .active {
            guard let (window, metric) = milestones(snapshot.reading) else { continue }
            let key = snapshot.id.uuidString
            let reached = window.reachedCount
            if let previous = counts[key], reached > previous, reached > 0 {
                fresh.append(String(localized: "\(snapshot.displayTitle): \(LongTermFormat.value(window.values[reached - 1], metric))"))
            }
            counts[key] = reached
        }
        UserDefaults.standard.set(counts, forKey: milestoneCountsKey)

        guard !fresh.isEmpty, isOn(.milestone), !workoutInProgress, !appIsActive else { return }
        let day = GoalActionEvaluator.dayKey(now, calendar: calendar)
        var state = dayState(day)
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard minute < latestMinute, !GoalNotifier.isQuiet(now, calendar: calendar), state.sent < dailyLimit
        else { return }
        post(id: "goal-milestone-\(day)-\(state.sent)",
             title: fresh.count == 1 ? String(localized: "Milestone reached") : String(localized: "\(fresh.count) milestones reached"),
             body: fresh.prefix(2).joined(separator: " · "), tickGoal: nil)
        state.sent += 1
        save(state)
    }

    private static func milestones(_ reading: GoalShapeReading?) -> (LongTermGoalMath.MilestoneWindow, LongTermMetric)? {
        switch reading {
        case .sum(let d)?: return d.milestones.map { ($0, d.metric) }
        case .target(let d)?: return d.milestones.map { ($0, d.metric) }
        case .best(let d)?: return d.milestones.map { ($0, .longestDistance) }
        default: return nil
        }
    }

    private static func post(id: String, title: String, body: String, tickGoal: GoalActionOccurrence?,
                             evening: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = !evening ? category : (tickGoal != nil ? eveningTickCategory : eveningCategory)
        content.threadIdentifier = "noop.goals"
        if let tickGoal {
            content.userInfo = ["goalId": tickGoal.action.id.uuidString, "day": tickGoal.day]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

}
