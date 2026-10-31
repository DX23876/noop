import Foundation
import UserNotifications
import StrandAnalytics
import StrandCore

/// The lock-screen side of activity detection (fork decision 2026-10-31): one local notification per
/// suggestion, at most `maxPerDay` a day, held overnight, paused for a week after `pauseAfterUnanswered`
/// went unanswered. Its buttons answer exactly as the Today prompt does, through `ActivitySuggestionCenter`.
/// A Live Activity is not used: without a push server one can only be started with the app in front.
enum ActivitySuggestionNotifier {
    static let categoryPrefix = "noop.activity."
    static let saveAction = "noop.activity.save"
    static let otherAction = "noop.activity.other"
    static let notTrainingAction = "noop.activity.notTraining"
    static let idKey = "suggestionId"

    static let maxPerDay = 2
    static let quietFromHour = 22
    static let quietUntilHour = 7
    static let pauseAfterUnanswered = 3
    static let pauseDays = 7

    private struct State: Codable {
        var day = ""
        var sentToday = 0
        /// Suggestion ids already notified, with when.
        var notified: [String: Int] = [:]
        var pausedUntil = 0
    }

    private static let stateKey = "noop.activityDetection.notifyState"

    /// Notifications are on with detection unless the wearer turned them off.
    static var isOn: Bool {
        ActivitySuggestionCenter.isEnabled
            && (UserDefaults.standard.object(forKey: ActivitySuggestions.notificationsKey) as? Bool ?? true)
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// One category per kind, so the save button can name the kind; added to the registered ones.
    static func registerCategories() {
        let notTraining = UNNotificationAction(identifier: notTrainingAction, title: String(localized: "Not training"),
                                               options: [])
        let other = UNNotificationAction(identifier: otherAction, title: String(localized: "Other kind…"),
                                         options: [.foreground])
        var ours: Set<UNNotificationCategory> = []
        for kind in ActivityDetectionScore.Kind.allCases {
            let save = UNNotificationAction(identifier: saveAction, title: saveTitle(kind), options: [])
            let actions = kind == .walk ? [save, notTraining] : [save, other, notTraining]
            ours.insert(UNNotificationCategory(identifier: categoryPrefix + kind.rawValue, actions: actions,
                                               intentIdentifiers: [], options: []))
        }
        let ids = Set(ours.map(\.identifier))
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            center.setNotificationCategories(existing.filter { !ids.contains($0.identifier) }.union(ours))
        }
    }

    static func saveTitle(_ kind: ActivityDetectionScore.Kind) -> String {
        kind == .walk ? String(localized: "Save as walk")
            : String(localized: "Save as \(ActivitySuggestionCenter.kindName(kind))")
    }

    /// Called whenever the suggestions are re-read: notifies the newest suggestion not yet notified.
    @MainActor
    static func update(with toAsk: [ActivitySuggestions.Suggestion], now: Int, calendar: Calendar = .current) {
        guard isOn, let next = toAsk.first else { return }
        var state = load()
        let today = ActivitySuggestions.dayKey(now, calendar)
        if state.day != today { state.day = today; state.sentToday = 0 }
        state.notified = state.notified.filter { $0.value > now - 30 * 86_400 }
        guard state.notified[next.id] == nil, now >= state.pausedUntil, state.sentToday < maxPerDay else { return }
        // Three notified and still open: stop asking for a week.
        let openIds = Set(toAsk.map(\.id))
        if state.notified.keys.filter(openIds.contains).count >= pauseAfterUnanswered {
            state.pausedUntil = now + pauseDays * 86_400
            save(state)
            return
        }
        state.notified[next.id] = now
        state.sentToday += 1
        save(state)
        post(next, now: now, calendar: calendar)
    }

    /// An answer from anywhere: the notification goes, and the unanswered count no longer includes it.
    static func answered(_ id: String) {
        var state = load()
        state.notified.removeValue(forKey: id)
        save(state)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier(id)])
        center.removePendingNotificationRequests(withIdentifiers: [identifier(id)])
    }

    static func identifier(_ id: String) -> String { categoryPrefix + "suggestion." + id }

    /// "Today from 14:05 to 14:40, about 35 minutes." The same words the Today prompt uses.
    static func spanLine(_ s: ActivitySuggestions.Suggestion, calendar: Calendar = .current) -> String {
        let fmt = AppClock.hourMinuteFormatter()
        let start = Date(timeIntervalSince1970: TimeInterval(s.start))
        let from = fmt.string(from: start), to = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(s.end)))
        let minutes = s.durationMinutes
        if calendar.isDateInToday(start) {
            return String(localized: "Today from \(from) to \(to). About \(minutes) minutes.")
        }
        if calendar.isDateInYesterday(start) {
            return String(localized: "Yesterday from \(from) to \(to). About \(minutes) minutes.")
        }
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return String(localized: "\(day) from \(from) to \(to). About \(minutes) minutes.")
    }

    /// "Today, 14:05 to 14:40": the span alone, for places that show the length as a number beside it.
    static func whenLine(_ s: ActivitySuggestions.Suggestion, calendar: Calendar = .current) -> String {
        let fmt = AppClock.hourMinuteFormatter()
        let start = Date(timeIntervalSince1970: TimeInterval(s.start))
        let from = fmt.string(from: start), to = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(s.end)))
        if calendar.isDateInToday(start) { return String(localized: "Today, \(from) to \(to)") }
        if calendar.isDateInYesterday(start) { return String(localized: "Yesterday, \(from) to \(to)") }
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return String(localized: "\(day), \(from) to \(to)")
    }

    static func title(_ s: ActivitySuggestions.Suggestion) -> String {
        s.track == .walk ? String(localized: "Walk detected") : String(localized: "Activity detected")
    }

    private static func post(_ s: ActivitySuggestions.Suggestion, now: Int, calendar: Calendar) {
        let content = UNMutableNotificationContent()
        content.title = title(s)
        content.body = spanLine(s, calendar: calendar)
        content.categoryIdentifier = categoryPrefix + s.likelyKind.rawValue
        content.userInfo = [idKey: s.id]
        content.threadIdentifier = "noop.activity"
        let trigger: UNNotificationTrigger?
        let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(now)))
        if hour >= quietFromHour || hour < quietUntilHour {
            trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: quietUntilHour, minute: 0),
                                                    repeats: false)
        } else {
            trigger = nil
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier(s.id), content: content, trigger: trigger))
    }

    /// A button or a tap on one of these notifications. Saving and "Not training" answer in place; a tap and
    /// "Other kind…" open the logging sheet for the suggestion (`ActivitySuggestionSheetHost`).
    @MainActor
    static func handle(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard let id = userInfo[idKey] as? String else { return }
        let center = ActivitySuggestionCenter.shared
        Task { @MainActor in
            await center.reload()
            guard let s = center.all.first(where: { $0.id == id }), s.state == .open else { return }
            switch actionIdentifier {
            case saveAction:
                await center.confirm(s, row: ActivitySuggestionCenter.prefill(s), origin: .notification)
            case notTrainingAction:
                await center.answer(s, .everyday, origin: .notification)
            default:
                center.openRequest = .init(suggestion: s, origin: .notification)
            }
        }
    }

    private static func load() -> State {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private static func save(_ state: State) {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: stateKey) }
    }
}
