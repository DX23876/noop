import Foundation
import UserNotifications
import StrandAnalytics
import WhoopStore

extension Notification.Name {
    /// Posted when the user taps the daily coach check-in notification, so the UI can jump to the Coach
    /// tab and refresh the brief. Fired from `NotificationPresenter.didReceive`.
    static let noopOpenCoachCheckIn = Notification.Name("noop.openCoachCheckIn")
}

/// Proactive coach check-in — a gentle, opt-in DAILY local notification that reminds the user their
/// coaching brief is ready, so the coach reaches out first (Bevel-style) instead of only answering when
/// asked. Tapping it opens the app; the Coach tab then auto-generates "Today's brief" via
/// `AICoachEngine.startBriefIfNeeded()`, so no networking happens in the background — the reminder is a
/// nudge, the brief is produced on open. Reliable on a sideloaded app (no critical-alert entitlement
/// needed) because it rides a repeating calendar trigger that lives in the notification centre.
///
/// Modelled on `WindDownNudge`: same authorization-first gating, same UserDefaults-backed settings, same
/// repeating `UNCalendarNotificationTrigger`. On-device only; nothing is sent anywhere.
@MainActor
enum CoachCheckIn {

    private static let requestId = "coach-checkin"

    // MARK: - Persisted settings (own keys; default OFF, opt-in like every automation)

    private enum K {
        static let enabled = "coachCheckIn.enabled"
        static let time = "coachCheckIn.timeMinutes"   // minutes since midnight; default 08:00
        static let mode = "coachCheckIn.mode"          // Mode.rawValue; default .fixed
        /// The most recently RESOLVED habitual wake time (minutes since midnight) under `.afterWake`,
        /// cached so the synchronous `schedule()` has a value without an async DB read. Absent until a
        /// refresh has learned one; while absent, `.afterWake` falls back to the fixed `timeMinutes`.
        static let resolvedWake = "coachCheckIn.resolvedWakeMinutes"
    }

    /// How the daily fire time is chosen. `.fixed` is the user's set clock time (the original, and still
    /// the default). `.afterWake` tracks the user's own habitual wake time, learned from recent sleep
    /// sessions and refreshed when the app is foregrounded — so the nudge lands when they actually wake
    /// rather than at a clock time that drifts out of step with their sleep.
    enum Mode: String { case fixed, afterWake }

    static var mode: Mode {
        (UserDefaults.standard.string(forKey: K.mode)).flatMap(Mode.init(rawValue:)) ?? .fixed
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    /// The CURRENT OS authorization state, re-checked live rather than assumed from the persisted
    /// `isEnabled` flag — that flag only reflects what happened the last time the toggle was touched in
    /// this app, not a permission the user later revoked in iOS Settings.
    static func isCurrentlyAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// The daily fire time as minutes since midnight, clamped to a valid minute-of-day. Defaults to 08:00.
    static var timeMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.time) as? Int ?? 8 * 60
        return min(max(v, 0), 24 * 60 - 1)
    }

    // MARK: - Public API

    /// The result of enabling the check-in — lets the UI react instead of persisting an "on" toggle that
    /// can never fire. `.denied` means notifications are off, so the caller should revert the switch and
    /// point the user at Settings.
    enum EnableOutcome { case scheduled, denied, off }

    /// Enable/disable and (re)schedule. Enabling gates on notification authorization FIRST (mirroring
    /// `WindDownNudge.setEnabled`): if undetermined it asks once and schedules on grant; if already denied
    /// it reports back rather than persisting a dead toggle. `completion` always runs on the main actor.
    static func setEnabled(_ on: Bool, completion: (@MainActor (EnableOutcome) -> Void)? = nil) {
        guard CoachFeaturePrefs.isEnabled || !on else {
            completion?(.off)
            return
        }
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [requestId])
            completion?(.off)
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    schedule()
                    completion?(.scheduled)
                case .notDetermined:
                    UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                            Task { @MainActor in
                                if granted {
                                    UserDefaults.standard.set(true, forKey: K.enabled)
                                    schedule()
                                    completion?(.scheduled)
                                } else {
                                    UserDefaults.standard.set(false, forKey: K.enabled)
                                    completion?(.denied)
                                }
                            }
                        }
                default:
                    // .denied (or any future non-authorized case) — don't fake an enabled toggle.
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    completion?(.denied)
                }
            }
        }
    }

    /// Update the daily fire time (minutes since midnight), rescheduling if enabled.
    static func setTimeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), 24 * 60 - 1), forKey: K.time)
        if isEnabled { schedule() }
    }

    /// Switch between a fixed clock time and wake-time tracking. Rescheduling immediately keeps the
    /// pending notification honest; the caller should also kick `refreshDynamicSchedule` so `.afterWake`
    /// picks up a freshly-learned wake time rather than waiting for the next foreground.
    static func setMode(_ newMode: Mode) {
        UserDefaults.standard.set(newMode.rawValue, forKey: K.mode)
        if isEnabled { schedule() }
    }

    /// The clock minute the reminder actually fires at. `.fixed` uses the user's set time; `.afterWake`
    /// uses the last resolved habitual wake time, falling back to the fixed time until one has been
    /// learned — so switching modes can never silently leave the reminder with no time to fire at.
    static var effectiveMinutes: Int {
        switch mode {
        case .fixed:
            return timeMinutes
        case .afterWake:
            if let resolved = UserDefaults.standard.object(forKey: K.resolvedWake) as? Int {
                return min(max(resolved, 0), 24 * 60 - 1)
            }
            return timeMinutes
        }
    }

    /// The fire time as a `Date` (today, hour/minute only) for a SwiftUI `.hourAndMinute` DatePicker.
    static var timeAsDate: Date {
        Calendar.current.date(
            bySettingHour: timeMinutes / 60, minute: timeMinutes % 60, second: 0, of: Date()
        ) ?? Date()
    }

    /// Persist the fire time from a picker `Date` (reads hour/minute only), rescheduling if enabled.
    static func setTime(from date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        setTimeMinutes((c.hour ?? 8) * 60 + (c.minute ?? 0))
    }

    // MARK: - Scheduling

    /// Actions offered on the check-in notification, so it can be dealt with from the banner instead of
    /// only by opening the app (or being swiped away and forgotten).
    ///
    /// Deliberately NOT "accept": there is nothing to accept here — the brief doesn't exist yet, it is
    /// generated when the app opens. Offering an accept would be accepting something unseen.
    enum Action {
        static let category = "coach-checkin"
        static let snooze = "coach-checkin-snooze"
        static let skipToday = "coach-checkin-skip"
        /// How long Snooze defers the reminder.
        static let snoozeMinutes = 120
    }

    /// Register the notification category. Called once at launch, before any notification can arrive —
    /// a category referenced by a notification but never registered simply shows no buttons.
    static func registerCategory() {
        let snooze = UNNotificationAction(identifier: Action.snooze,
                                          title: String(localized: "Remind me in 2 hours"),
                                          options: [])
        let skip = UNNotificationAction(identifier: Action.skipToday,
                                        title: String(localized: "Not today"),
                                        options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Action.category,
                                   actions: [snooze, skip],
                                   intentIdentifiers: [],
                                   options: [])
        ])
    }

    /// Defer today's reminder by `snoozeMinutes`, as a ONE-OFF request beside the repeating daily one.
    /// The daily trigger is left untouched, so snoozing today never quietly cancels tomorrow.
    static func snooze() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your coach has today's brief")
        content.body = String(localized: "Open NOOP for your readiness and today's plan.")
        content.sound = .default
        content.categoryIdentifier = Action.category

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(Action.snoozeMinutes * 60), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(requestId)-snoozed", content: content, trigger: trigger))
    }

    private static func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestId])

        let content = UNMutableNotificationContent()
        // Deliberately GENERIC, and it has to be. This is a REPEATING calendar trigger: its content is
        // fixed when scheduled and reused every day thereafter, without the app running. Naming today's
        // actual readiness would therefore quote whatever was true the last time NOOP was opened —
        // possibly days ago. A stale number in a notification is worse than no number, and this project
        // does not state figures it can't stand behind. The brief itself is generated on open, where the
        // data is current.
        content.title = String(localized: "Your coach has today's brief")
        content.body = String(localized: "Open NOOP for your readiness and today's plan.")
        content.sound = .default
        content.categoryIdentifier = Action.category

        let minute = effectiveMinutes
        var comps = DateComponents()
        comps.hour = minute / 60
        comps.minute = minute % 60
        // repeats: true → a daily calendar trigger that survives relaunch (it lives in the notification
        // centre, not the process), so the check-in keeps firing each day without the app running.
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: requestId, content: content, trigger: trigger))
    }

    // MARK: - Wake-time tracking (.afterWake)

    /// How many recent nights to learn the habitual wake time from. A fortnight smooths a single odd
    /// night (one very early or very late wake) without letting a wake time from a month ago, before a
    /// schedule change, still count.
    private static let wakeWindowNights = 14

    /// The minimum learned resolved wake minute, exposed for the UI's readout. Nil until a refresh has
    /// learned one from enough nights.
    static var resolvedWakeMinutes: Int? {
        UserDefaults.standard.object(forKey: K.resolvedWake) as? Int
    }

    /// Recompute the habitual wake time from recent sleep and reschedule — but only when it would change
    /// anything (enabled AND in `.afterWake`). Safe to call on every foreground: it's one bounded read
    /// and a reschedule, and a no-op in fixed mode or when the check-in is off.
    static func refreshDynamicScheduleIfNeeded(repo: Repository) async {
        guard isEnabled, mode == .afterWake else { return }
        await refreshDynamicSchedule(repo: repo)
    }

    /// Learn the habitual wake minute from the last `wakeWindowNights` nights' wake times and cache it,
    /// then reschedule so the change takes effect. When there isn't enough history yet the cache is left
    /// untouched and `effectiveMinutes` keeps falling back to the fixed time, so the reminder never stops.
    ///
    /// Reads via `Repository.allSleepSessions`, the same union `habitualMidsleepSec()` uses — NOT
    /// `sleepSessions(from:to:limit:)`, which only unions the IMPORTED source ids (a Bluetooth-only user
    /// with no WHOOP/Health import would never see a learned wake time, #coach-checkin-wake-fix) and whose
    /// `ORDER BY startTs ASC LIMIT ?` drops the NEWEST nights once a window holds more rows than `limit`
    /// (the opposite of "the last N nights"). `mainNightWakeMinutes` then does the actual night selection.
    static func refreshDynamicSchedule(repo: Repository) async {
        let sessions = await repo.allSleepSessions(days: wakeWindowNights + 5)
        let blocks = sessions.map { (start: $0.effectiveStartTs, end: $0.endTs) }
        let habitualMidsleep = await repo.habitualMidsleepSec()
        let localWakeMinutes = mainNightWakeMinutes(blocks: blocks, nights: wakeWindowNights,
                                                     habitualMidsleepSec: habitualMidsleep)

        guard let resolved = habitualWakeMinutes(fromLocalMinutes: localWakeMinutes) else {
            // Not enough nights yet — leave the fallback in place, don't clear a previously-good value.
            if isEnabled, mode == .afterWake { schedule() }
            return
        }
        UserDefaults.standard.set(resolved, forKey: K.resolvedWake)
        if isEnabled, mode == .afterWake { schedule() }
    }

    /// The day's MAIN-NIGHT wake minute-of-day, for each of the most recent `nights` distinct local days
    /// that have one — mirroring the exact selector `AnalyticsEngine.analyzeDay` and the Sleep tab hero use
    /// so a nap sharing a day with the real night never contributes its own wake time, and a night split by
    /// a short wake still resolves to ONE wake time (the winning bridged group's latest `end`). Blocks are
    /// bucketed by the LOCAL day their `end` falls on — the SAME attribution `analyzeDay` uses
    /// (`tsInDay($0.end)`), so a night ending just after midnight buckets with its wake, not its bedtime
    /// (day keys sort lexicographically = chronologically, so no `Calendar` arithmetic is needed to pick
    /// "the most recent N"). Each timestamp uses ITS OWN UTC offset (so a window spanning a DST change
    /// still maps every wake to the wall-clock minute the user saw). Pure and database-free; the caller
    /// supplies already-fetched blocks. `offsetSec` defaults to the real `TimeZone.current` but is
    /// injectable so tests can pin a deterministic (or DST-transitioning) offset without depending on the
    /// machine's system timezone.
    nonisolated static func mainNightWakeMinutes(
        blocks: [(start: Int, end: Int)], nights: Int, habitualMidsleepSec: Int?,
        offsetSec: (Int) -> Int = { ts in
            TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(ts)))
        }
    ) -> [Int] {
        guard !blocks.isEmpty else { return [] }
        var byDay: [String: [(start: Int, end: Int)]] = [:]
        for b in blocks {
            guard b.end > b.start else { continue }
            byDay[AnalyticsEngine.dayString(b.end, offsetSec: offsetSec(b.end)), default: []].append(b)
        }
        let recentDays = byDay.keys.sorted().suffix(nights)

        var wakeMinutes: [Int] = []
        for day in recentDays {
            guard let dayBlocks = byDay[day] else { continue }
            let dayOffset = offsetSec(dayBlocks.map(\.end).max() ?? 0)
            let nightBlocks = dayBlocks.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) }
            guard let groupIdx = SleepStageTotals.mainNightGroupIndices(
                nightBlocks, offsetSec: dayOffset, habitualMidsleepSec: habitualMidsleepSec) else { continue }
            let wakeEnd = groupIdx.map { dayBlocks[$0].end }.max() ?? 0
            let secondsPerDay = 86_400
            let wakeOffset = offsetSec(wakeEnd)
            let localSec = (((wakeEnd + wakeOffset) % secondsPerDay) + secondsPerDay) % secondsPerDay
            wakeMinutes.append(localSec / 60)
        }
        return wakeMinutes
    }

    /// The habitual wake time (minutes since midnight) as the MEDIAN of recent nights' local wake minutes,
    /// or nil below `minimumNights` — a habit the reminder can rely on, not a guess off one or two nights.
    ///
    /// Median rather than mean on purpose: it shrugs off the odd 04:00 alarm or 11:00 lie-in that would
    /// drag an average away from the time the user actually wakes on a normal day. Pure and database-free
    /// so it unit-tests without a strap or store. Wake times realistically cluster in the morning and
    /// don't straddle midnight, so a plain minute-of-day median needs no circular-statistics handling.
    nonisolated static func habitualWakeMinutes(fromLocalMinutes minutes: [Int],
                                                minimumNights: Int = 3) -> Int? {
        let valid = minutes.filter { (0..<24 * 60).contains($0) }.sorted()
        guard valid.count >= minimumNights else { return nil }
        let mid = valid.count / 2
        if valid.count % 2 == 1 {
            return valid[mid]
        }
        return (valid[mid - 1] + valid[mid]) / 2
    }
}
