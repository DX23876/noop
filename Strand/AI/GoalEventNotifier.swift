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
    static let dailyLimit = GoalEventPlan.dailyLimit
    /// Never later than this minute of the day (21:00).
    static let latestMinute = GoalEventPlan.latestMinute

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

    /// The plan's bookkeeping, one record. Before it existed the day, the told badges and the milestone counts
    /// lived under keys of their own; they are read once into it, so nothing already told is told again.
    private static let stateKey = "goals.notify.state"
    private static let dayStateKey = "goals.notify.day"
    private static let toldBadgesKey = "goals.notify.toldBadges"

    private struct LegacyDayState: Codable {
        var day: String
        var sent = 0
        var reached: [String] = []
        var eveningSent = false
    }

    private static func loadState() -> GoalEventPlan.State {
        let d = UserDefaults.standard
        if let data = d.data(forKey: stateKey), let state = try? JSONDecoder().decode(GoalEventPlan.State.self, from: data) {
            return state
        }
        var state = GoalEventPlan.State()
        if let data = d.data(forKey: dayStateKey), let old = try? JSONDecoder().decode(LegacyDayState.self, from: data) {
            state.day = old.day; state.sent = old.sent; state.reached = old.reached; state.eveningSent = old.eveningSent
        }
        state.toldBadges = d.stringArray(forKey: toldBadgesKey) ?? []
        state.milestoneCounts = (d.dictionary(forKey: milestoneCountsKey) as? [String: Int]) ?? [:]
        state.milestoneRoutes = (d.dictionary(forKey: milestoneRoutesKey) as? [String: String]) ?? [:]
        return state
    }

    private static func save(_ state: GoalEventPlan.State) {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: stateKey) }
    }

    private static func context(now: Date, calendar: Calendar) -> GoalEventPlan.Context {
        GoalEventPlan.Context(kinds: Set(Kind.allCases.filter(isOn).compactMap { GoalEventPlan.Kind(rawValue: $0.rawValue) }),
                              workoutInProgress: workoutInProgress, appIsActive: appIsActive,
                              quiet: GoalNotifier.isQuiet(now, calendar: calendar),
                              eveningMinute: eveningMinute(now: now, calendar: calendar),
                              seenBadgeIds: GoalPrefs.seenBadgeIds)
    }

    static func evaluate(todayActions: [GoalActionOccurrence], motivation: GoalMotivationSnapshot?,
                         now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        let (message, state) = GoalEventPlan.daily(todayActions: todayActions, motivation: motivation, state: loadState(),
                                                   context: context(now: now, calendar: calendar), now: now,
                                                   calendar: calendar)
        save(state)
        if let message { post(message) }
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
    private static let milestoneRoutesKey = "goals.notify.milestoneRoutes"

    /// A long-term goal passing a waypoint (plan Q25), as `GoalEventPlan.longTerm` decides it.
    static func evaluateLongTerm(_ snapshots: [GoalTrackingSnapshot], now: Date = Date(),
                                 calendar: Calendar = .autoupdatingCurrent) {
        let (message, state) = GoalEventPlan.longTerm(snapshots, state: loadState(),
                                                      context: context(now: now, calendar: calendar), now: now,
                                                      calendar: calendar)
        save(state)
        if let message { post(message) }
    }

    private static func post(_ message: GoalEventPlan.Message) {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        content.categoryIdentifier = !message.evening ? category
            : (message.tickGoalId != nil ? eveningTickCategory : eveningCategory)
        content.threadIdentifier = "noop.goals"
        if let goal = message.tickGoalId, let day = message.tickDay {
            content.userInfo = ["goalId": goal, "day": day]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: message.id, content: content,
                                                                     trigger: nil))
    }

}
