import AppIntents
import Foundation

/// The Lock Screen / Dynamic Island workout controls reach the app through this bridge. The intent type has
/// to compile into the widget extension (the button lives there), but a `LiveActivityIntent` always RUNS in
/// the app's process, launching it in the background if needed; the app installs the handler at launch, so
/// in the widget process it simply stays nil and is never called.
@MainActor
enum WorkoutActivityActions {
    static var togglePause: (() -> Void)?
    static var completeStrengthSet: ((UUID, UUID) async -> Void)?
    static var adjustStrengthRest: ((UUID, Int, Int) async -> Void)?
}

/// Complete only the set named by the Live Activity. A delayed action cannot complete the next set.
struct CompleteStrengthSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete strength set"
    static let isDiscoverable = false

    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Set") var setId: String

    init() {}
    init(sessionId: String, setId: String) {
        self.sessionId = sessionId
        self.setId = setId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let session = UUID(uuidString: sessionId), let set = UUID(uuidString: setId) {
            await WorkoutActivityActions.completeStrengthSet?(session, set)
        }
        return .result()
    }
}

/// Change only the rest timer whose end was displayed when this button was tapped.
struct AdjustStrengthRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Adjust strength rest"
    static let isDiscoverable = false

    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Rest end") var expectedEnd: Int
    @Parameter(title: "Seconds") var seconds: Int

    init() {}
    init(sessionId: String, expectedEnd: Int, seconds: Int) {
        self.sessionId = sessionId
        self.expectedEnd = expectedEnd
        self.seconds = seconds
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let session = UUID(uuidString: sessionId) {
            await WorkoutActivityActions.adjustStrengthRest?(session, expectedEnd, seconds)
        }
        return .result()
    }
}

/// Pause or resume the running workout from the Live Activity, without opening NOOP. Ending is deliberately
/// NOT an intent: the End control opens the app and asks, so a tap in a pocket can never finish a run.
struct ToggleWorkoutPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume workout"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        WorkoutActivityActions.togglePause?()
        return .result()
    }
}
