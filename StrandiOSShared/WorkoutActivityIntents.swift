import AppIntents
import Foundation

/// The Lock Screen / Dynamic Island workout controls reach the app through this bridge. The intent type has
/// to compile into the widget extension (the button lives there), but a `LiveActivityIntent` always RUNS in
/// the app's process, launching it in the background if needed; the app installs the handler at launch, so
/// in the widget process it simply stays nil and is never called.
@MainActor
enum WorkoutActivityActions {
    static var togglePause: (() -> Void)?
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
