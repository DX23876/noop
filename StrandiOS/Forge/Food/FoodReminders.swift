#if os(iOS)
import Foundation
@preconcurrency import UserNotifications
import StrandCore
import StrandAnalytics

/// The food notifications (owner, 2026-11-21): a look back each morning and, only when one meal can still close a
/// gap, a reminder in the evening. The content comes from the core (`FoodNotice`); this file words and delivers it.
///
/// Default off like every notification in the project, turned on in Food data or from the Food page's one-time
/// invitation. Following `BodyMeasurementReminder`, a denied permission is surfaced instead of arming reminders the
/// system will never deliver. A notification is planned with its words already in it, so both are planned again
/// whenever the food log changes or the page loads: the morning look back always reads the latest log of the day.
@MainActor
enum FoodReminders {
    static let morningKey = "food.remind.morning"
    static let eveningKey = "food.remind.evening"
    /// The warning while logging; on unless turned off, and only ever shown while losing weight.
    static let warnKey = "food.warn.enabled"
    /// The Food page's invitation to turn the reminders on, shown once.
    static let invitedKey = "food.remind.invited"

    private static let morningId = "food-morning"
    private static let eveningId = "food-evening"

    static var morningOn: Bool { UserDefaults.standard.bool(forKey: morningKey) }
    static var eveningOn: Bool { UserDefaults.standard.bool(forKey: eveningKey) }
    static var warnOn: Bool { UserDefaults.standard.object(forKey: warnKey) as? Bool ?? true }

    /// Turns a reminder on or off. On asks for permission first and stays off when it is refused.
    static func set(_ key: String, on: Bool) async -> Bool {
        guard on else {
            UserDefaults.standard.set(false, forKey: key)
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: [key == morningKey ? morningId : eveningId])
            return true
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let allowed = granted || settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        UserDefaults.standard.set(allowed, forKey: key)
        return allowed
    }

    /// Plans them again from the store, for the app becoming active: a reminder is a single notification, and the
    /// Food page (which also plans them when it loads) may not be opened for days. Nothing is read while both are off.
    static func replan(repo: Repository, profile: UserProfile) async {
        guard morningOn || eveningOn else { return }
        // Loading the page's model plans them (`loadQuality` ends in `refresh`).
        await ForgeFoodModel().load(repo: repo, profile: profile)
    }

    /// Plans tomorrow morning's look back and tonight's reminder from the model's current log.
    static func refresh(model: ForgeFoodModel, now: Date = .now) {
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        let today = Repository.localDayKey(now)
        center.removePendingNotificationRequests(withIdentifiers: [morningId, eveningId])

        if morningOn, let recap = model.tomorrowRecap(today: today), let content = morningContent(recap),
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            let weekday = calendar.component(.weekday, from: tomorrow)
            // Half an hour after the wake time the alarm settings know, so it waits for the morning.
            let minutes = min(WindDownNudge.wakeMinutes(forWeekday: weekday) + 30, 23 * 60)
            var when = calendar.dateComponents([.year, .month, .day], from: tomorrow)
            when.hour = minutes / 60
            when.minute = minutes % 60
            center.add(UNNotificationRequest(identifier: morningId, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }

        if eveningOn, let gap = model.eveningGap(today: today) {
            let weekday = calendar.component(.weekday, from: now)
            let wake = WindDownNudge.wakeMinutes(forWeekday: weekday % 7 + 1)
            let bed = (wake - WindDownNudge.sleepNeedMinutes + 24 * 60) % (24 * 60)
            let time = FoodNotice.eveningTime(usualBedtime: DateComponents(hour: bed / 60, minute: bed % 60))
            var when = calendar.dateComponents([.year, .month, .day], from: now)
            when.hour = time.hour
            when.minute = time.minute
            if let fire = calendar.date(from: when), fire > now {
                center.add(UNNotificationRequest(identifier: eveningId, content: eveningContent(gap),
                                                 trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
            }
        }
    }

    // MARK: Words

    static func morningContent(_ recap: FoodNotice.Recap) -> UNMutableNotificationContent? {
        guard recap.note != nil || !recap.badges.isEmpty else { return nil }
        let content = UNMutableNotificationContent()
        if let note = recap.note {
            let figure = FoodText.note(note.score)
            content.title = switch recap.kind {
            case .day: String(localized: "Yesterday's food: \(figure) of 10")
            case .week: String(localized: "Your week of food: \(figure) of 10")
            case .month: String(localized: "Your last four weeks of food: \(figure) of 10")
            }
        } else {
            content.title = String(localized: "New badge")
        }
        var lines: [String] = []
        if let note = recap.note, let previous = recap.previous {
            let change = note.score - previous.score
            if abs(change) >= 0.1 {
                lines.append(change > 0 ? String(localized: "Up \(FoodText.note(change)) on the one before.")
                                        : String(localized: "Down \(FoodText.note(-change)) on the one before."))
            }
        }
        if let strongest = recap.strongest {
            lines.append(String(localized: "Strong: \(FoodText.component(strongest))."))
        }
        if let weakest = recap.weakest {
            lines.append(String(localized: "Room to grow: \(FoodText.component(weakest))."))
        }
        switch recap.goal {
        case .over: lines.append(String(localized: "Above your energy goal; today is a new day."))
        case .belowFloor: lines.append(String(localized: "Less than your body needs; eat enough today."))
        case .inRange: lines.append(String(localized: "Energy on goal."))
        case .under, nil: break
        }
        for earned in recap.badges.suffix(2) {
            lines.append(String(localized: "New badge: \(FoodText.badgeTitle(earned.badge))."))
        }
        content.body = lines.joined(separator: " ")
        content.sound = .default
        content.threadIdentifier = "food"
        return content
    }

    static func eveningContent(_ gap: FoodNotice.Gap) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "One meal can still do it")
        var lines: [String] = []
        if let protein = gap.proteinG {
            lines.append(String(localized: "About \(FoodText.grams(protein)) g protein are still open today."))
        }
        if let portions = gap.vegetablePortions {
            lines.append(String(localized: "Some vegetables would help: \(FoodText.grams(portions)) more portions for two today."))
        }
        content.body = lines.joined(separator: " ")
        content.sound = .default
        content.threadIdentifier = "food"
        return content
    }
}
#endif
