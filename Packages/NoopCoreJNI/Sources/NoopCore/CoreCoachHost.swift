import Foundation

// The Android core's answers to the hooks each target that links the coach defines (Android parity plan, Coach
// extraction). For now they are the quiet ones: no reminder notifications, the API key only in memory as Kotlin
// hands it in (`CoreCoach`), no semantic memory, the default identity and the core's own goal tracking model. Apple's answers live beside the app (`PlanReminder.swift`,
// `SecretVault+Keychain.swift`, `CoachSemanticMemory.swift`, `CoachAppHooks+App.swift`).

/// No plan reminders or memory updates on Android yet.
struct CoreCoachPlanEffects: CoachPlanEffects {
    func scheduleReminder(for proposal: PlanProposal) {}
    func cancelReminder(for id: UUID) {}
    func proposalsSaved(_ proposals: [PlanProposal]) {}
}

@MainActor
func coachPlanEffects() -> any CoachPlanEffects { CoreCoachPlanEffects() }

/// The key Kotlin hands in with `coach.configure`, held for this process only. Android keeps it at rest in its
/// encrypted preferences (`AiKeyStore`), so nothing is written to disk here.
struct CoreSecretVault: SecretVault {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var items: [String: Data] = [:]

    func read(service: String, account: String) -> Data? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.items[service + "/" + account]
    }
    func write(_ data: Data, service: String, account: String) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.items[service + "/" + account] = data
        return true
    }
    func delete(service: String, account: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.items[service + "/" + account] = nil
    }
}

func secretVault() -> any SecretVault { CoreSecretVault() }

@MainActor
private let coreMemoryIndex = NoCoachMemoryIndex()

@MainActor
func coachMemoryIndex() -> any CoachMemoryIndex { coreMemoryIndex }

/// The core's goal tracking model, no identity name, and no notifications.
@MainActor
struct CoreCoachAppHooks: CoachAppHooks {
    static let goalTracking = GoalTrackingModel()
    var goalTracking: GoalTrackingModel { Self.goalTracking }
    var identityPreamble: String { CoachIdentity.default.identityPreamble }
    func planProposed(_ proposal: PlanProposal) {}
    func proactiveSignal(_ signal: ProactiveSignal, level: ProactiveLevel) {}
}

@MainActor
func coachAppHooks() -> any CoachAppHooks { CoreCoachAppHooks() }
