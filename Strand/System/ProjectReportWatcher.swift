import Foundation
import StrandCore
#if canImport(UserNotifications)
import UserNotifications
#endif

// ProjectReportWatcher.swift — telling somebody that their own reported problem moved.
//
// This is the half that turns a drop box into a conversation. Without it the owner's question reaches
// nobody until the reporter happens to open the page again, and a question nobody answers is the same
// as no question.
//
// Four rules, and they are the whole design:
//
// 1. **Only your own report, and only when something really happened.** The status moved, or the
//    developer said something. Not "a new version is out", not somebody else's report, not a count.
//    `RoadmapView` states the page's own rule: no badge, no bell, no unread dot, no "new" markers.
//    This is the one carve-out from it, and it is narrow on purpose.
// 2. **Nothing is asked for.** No permission prompt of its own: with no notification right the check
//    still runs and the screen still shows the change the next time it is opened.
// 3. **No polling.** There is no push here, and there will not be: push needs an account and a
//    service that knows devices. So it looks when the app comes forward, at most every six hours, and
//    whenever the thread is opened anyway. Four requests a day for an event that happens twice a week.
// 4. **It can be switched off**, and the master switch covers it too: nothing leaves the device means
//    this does not ask either.

/// Checks this device's own reports and says which of them moved since the wearer last looked.
enum ProjectReportWatcher {
    /// The wearer's switch, under Alerts. On by default: somebody who reports a problem wants the
    /// question that follows.
    static let enabledDefault = "projectReportNotices"
    /// When this last asked, so coming back to the app ten times in an hour asks once.
    static let lastCheckDefault = "projectReportLastCheck"
    static let interval: TimeInterval = 6 * 60 * 60

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefault) as? Bool ?? true
    }

    static func setOn(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledDefault)
    }

    /// What a check found: the reports that moved, and what to say about each.
    struct Change: Equatable {
        let code: String
        let title: String
        let status: ProjectReportStatus
        /// True when the developer has said something new, rather than only a label having moved.
        let answered: Bool
    }

    /// Look, unless it has been looked at recently. `force` is the thread screen, which looks anyway.
    static func checkIfDue(service: ProjectService?, store: ProjectReportStore = .standard,
                           defaults: UserDefaults = .standard, now: Date = Date(),
                           force: Bool = false) async -> [Change] {
        guard isOn(defaults), let service else { return [] }
        if !force {
            let last = defaults.object(forKey: lastCheckDefault) as? Date ?? .distantPast
            guard now.timeIntervalSince(last) >= interval else { return [] }
        }
        defaults.set(now, forKey: lastCheckDefault)
        return await check(service: service, store: store)
    }

    /// The check itself. Reads each remembered report once and records what was seen, so the same
    /// change is never announced twice.
    static func check(service: ProjectService, store: ProjectReportStore = .standard) async -> [Change] {
        var changes: [Change] = []
        for entry in store.all() {
            // A report that was fixed or refused is over, and the wearer has already been told. Asking
            // after it again every six hours for the rest of the install's life is a request that can
            // only ever confirm what is already on their screen.
            guard !ProjectReportWatcher.isSettled(entry.seenStatus) else { continue }
            guard let thread = await service.thread(code: entry.code) else { continue }
            let answered = thread.messages.count > entry.seenMessages
                && !(thread.messages.last?.mine ?? true)
            let moved = thread.status != entry.seenStatus
            _ = store.seen(code: entry.code, status: thread.status, messages: thread.messages.count)
            if moved || answered {
                changes.append(Change(code: entry.code, title: entry.title,
                                      status: thread.status, answered: answered))
            }
        }
        return changes
    }

    /// One notification per report that moved. Never a summary across several: each one is about a
    /// thing the reader wrote themselves, and a count would be the badge this page does not have.
    #if canImport(UserNotifications)
    @MainActor
    static func announce(_ changes: [Change]) async {
        guard !changes.isEmpty else { return }
        let centre = UNUserNotificationCenter.current()
        // Asked for nowhere here: if the app has no right to notify, the screen still shows it.
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional else { return }

        for change in changes {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Your report")
            content.body = change.answered
                ? String(localized: "The developer answered you.")
                : ProjectReportWatcher.statusLine(change.status)
            content.sound = nil
            let request = UNNotificationRequest(identifier: "project.report.\(change.code)",
                                                content: content, trigger: nil)
            try? await centre.add(request)
        }
    }
    #endif

    /// Whether a report has reached a state that cannot move again on its own.
    static func isSettled(_ status: ProjectReportStatus) -> Bool {
        status == .fixed || status == .notPlanned
    }

    /// What a moved status is worth saying. Only the two that are news to the person who reported it.
    static func statusLine(_ status: ProjectReportStatus) -> String {
        switch status {
        case .fixed: return String(localized: "It is fixed.")
        case .working: return String(localized: "Somebody is working on it.")
        case .notPlanned: return String(localized: "It will not be changed.")
        case .read, .arrived: return String(localized: "It has been read.")
        }
    }
}
