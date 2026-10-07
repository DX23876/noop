#if os(iOS)
import Foundation
import AppIntents

/// Queue of actions requested by an App Intent while the app may be suspended. Intents can't reach
/// into the running `AppModel` directly (BLE only lives in the foreground app), so they enqueue here
/// and the app drains the queue when it next becomes active.
@MainActor
enum PendingIntents {
    typealias Action = PendingIntentQueue.Action
    private static var queue: PendingIntentQueue {
        PendingIntentQueue(defaults: UserDefaults(suiteName: WidgetSnapshot.suiteName))
    }

    @discardableResult
    static func append(_ action: Action, at date: Date? = nil) -> Bool {
        queue.append(action, at: date)
    }

    /// Set by `OpenGoalsIntent`; the shell consumes it when it becomes active and opens the goals.
    static var openGoalsRequested: Bool {
        get { UserDefaults(suiteName: WidgetSnapshot.suiteName)?.bool(forKey: "noop.pendingOpenGoals") ?? false }
        set { UserDefaults(suiteName: WidgetSnapshot.suiteName)?.set(newValue, forKey: "noop.pendingOpenGoals") }
    }

    static func appendAskCoach(question: String, at date: Date? = nil) {
        queue.appendAskCoach(question: question, at: date)
    }

    static func consumeCoachQuestion() -> String? { queue.consumeCoachQuestion() }
    static func drain() -> [PendingIntentQueue.Request] { queue.drain() }
}

/// Record a timestamped "moment" — the iOS analogue of the strap double-tap "mark a moment" action.
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Moment"
    static var description = IntentDescription("Record a timestamped moment in NOOP.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.append(.markMoment, at: Date())
        return .result(dialog: "Moment marked.")
    }
}

/// The typed sleep mark selected by a Shortcut; these choices match the existing Sleep card.
enum SleepMarkShortcutType: String, AppEnum {
    case bedtime, wake
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sleep Mark"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .bedtime: "Bedtime", .wake: "Wake"
    ]
    var action: PendingIntents.Action { self == .bedtime ? .markBedtime : .markWake }
}

enum SleepMarkShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case queueUnavailable
    var localizedStringResource: LocalizedStringResource {
        "NOOP couldn't queue the sleep mark. Open NOOP and try again."
    }
}

/// Capture the invocation time without foregrounding NOOP; the existing active-scene drain saves it.
struct LogSleepMarkIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Sleep Mark"
    static var description = IntentDescription("Queue a bedtime or wake mark. NOOP saves it when the app next becomes active.")
    static var openAppWhenRun = false

    @Parameter(title: "Sleep Mark", default: .bedtime)
    var markType: SleepMarkShortcutType

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PendingIntents.append(markType.action, at: Date()) else {
            throw SleepMarkShortcutError.queueUnavailable
        }
        return .result(dialog: "Sleep mark queued for the next time NOOP becomes active.")
    }
}

/// Send a confirming haptic buzz to the strap. Opens the app so the live BLE link can deliver it.
struct BuzzStrapIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Strap"
    static var description = IntentDescription("Send a haptic buzz to your WHOOP strap.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntents.append(.buzz)
        return .result()
    }
}

/// "How's my recovery?" (redesign briefing §9). A READ, unlike the other two intents: it answers straight
/// from the last-published `WidgetSnapshot` (the same App Group data the widgets read), so it works without
/// opening the app or touching BLE — Siri can answer even with NOOP backgrounded or the strap disconnected.
/// `openAppWhenRun` stays false; there's nothing for the foreground app to do.
struct RecoveryStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Recovery Status"
    static var description = IntentDescription("Hear today's Charge (recovery) score.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snap = WidgetSnapshot.load(), let recovery = snap.recovery else {
            return .result(dialog: "No recovery score yet today.")
        }
        return .result(dialog: "Your Charge is \(recovery) percent.")
    }
}

/// Pull the strap's stored history now: the Shortcuts twin of the "Sync now" button, run WITHOUT opening NOOP.
/// iOS runs an in-app intent inside NOOP's own process (launching or resuming it in the background), where the
/// strap link lives under the bluetooth-central background mode, so the offload carries on after this returns.
/// The spoken/shown reply reports only what this path observed about the sync starting.
///
/// `LiveActivityIntent`, not plain `AppIntent`: that is what lets it START the strap-sync Live Activity
/// (the Dynamic Island "Connecting… / Syncing… N chunks" readout) from the background. A plain intent
/// running in a background-launched app is refused by ActivityKit.
struct SyncStrapIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Sync Strap"
    static var description = IntentDescription("Pull your WHOOP strap's stored history into NOOP now.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await AppModel.startStrapSyncFromShortcut() {
        case .started:               return .result(dialog: "Syncing your strap.")
        case .alreadyRunning:        return .result(dialog: "Your strap is already syncing.")
        case .willSyncWhenConnected: return .result(dialog: "NOOP is connecting to your strap and will sync as soon as it's ready.")
        case .strapNotReady:         return .result(dialog: "Your strap isn't connected to NOOP yet, so the sync didn't start.")
        case .notStarted:            return .result(dialog: "NOOP couldn't start the sync. Open NOOP to see the strap log.")
        }
    }
}

/// K9: Ask the Coach a question via Siri. Queues the question and opens the app, which sends it
/// to the configured provider and surfaces the response. The question is spoken or typed in Siri;
/// the app handles the actual network call using the user's saved key.
struct AskCoachIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Coach"
    static var description = IntentDescription("Ask your NOOP Coach a question about your recovery, sleep, or training.")
    static var openAppWhenRun = true

    /// The question to ask, populated by Siri from the user's spoken phrase.
    @Parameter(title: "Question")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.appendAskCoach(question: question, at: Date())
        return .result(dialog: "Opening Coach with your question: \(question)")
    }
}

/// "How are my goals?" (goals plan §13). A read from the last-published goal snapshot, like Recovery
/// Status: Siri answers with NOOP in the background, in the same words the app shows.
struct GoalsStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Goals Status"
    static var description = IntentDescription("Hear how your weekly and monthly goals stand.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snap = GoalWidgetSnapshot.load(), !snap.goals.isEmpty else {
            return .result(dialog: "You have no weekly or monthly goals yet.")
        }
        let lines = snap.goals.prefix(3).map { "\($0.name): \($0.stateWord), \($0.remaining)" }
        return .result(dialog: "\(snap.summary). \(lines.joined(separator: ". ")).")
    }
}

/// Opens the goals overview.
struct OpenGoalsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Goals"
    static var description = IntentDescription("Open your goals overview in NOOP.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntents.openGoalsRequested = true
        return .result()
    }
}

/// Surfaces NOOP's intents to Siri, Spotlight, and the Shortcuts gallery without any user setup.
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncStrapIntent(),
                    phrases: [
                        "Sync my \(.applicationName) strap",
                        "Sync \(.applicationName)",
                    ],
                    shortTitle: "Sync Strap",
                    systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark a moment in \(.applicationName)"],
                    shortTitle: "Mark a Moment",
                    systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: LogSleepMarkIntent(),
                    phrases: ["Log a sleep mark in \(.applicationName)"],
                    shortTitle: "Log Sleep Mark",
                    systemImageName: "bed.double")
        AppShortcut(intent: BuzzStrapIntent(),
                    phrases: ["Buzz my \(.applicationName) strap"],
                    shortTitle: "Buzz Strap",
                    systemImageName: "waveform.path")
        AppShortcut(intent: RecoveryStatusIntent(),
                    phrases: ["How's my recovery in \(.applicationName)", "What's my Charge in \(.applicationName)"],
                    shortTitle: "Recovery Status",
                    systemImageName: "bolt.heart.fill")
        AppShortcut(intent: GoalsStatusIntent(),
                    phrases: ["How are my goals in \(.applicationName)", "How am I doing on my \(.applicationName) goals"],
                    shortTitle: "Goals Status",
                    systemImageName: "target")
        AppShortcut(intent: OpenGoalsIntent(),
                    phrases: ["Open my goals in \(.applicationName)", "Show my \(.applicationName) goals"],
                    shortTitle: "Open Goals",
                    systemImageName: "target")
        // K9: "Ask Coach" via Siri — opens Coach with the question and sends it. The question
        // parameter is provided via the Shortcuts app or Siri prompts for it when the phrase fires.
        AppShortcut(intent: AskCoachIntent(),
                    phrases: [
                        "Ask \(.applicationName) about my recovery",
                        "Ask \(.applicationName) how I'm doing",
                        "Ask \(.applicationName) Coach",
                    ],
                    shortTitle: "Ask Coach",
                    systemImageName: "sparkles")
    }
}
#endif
