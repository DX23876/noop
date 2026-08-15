import Foundation

/// A grouping of coach tools by what a user might want to grant or withhold, independent of any single
/// tool. Coarser than per-tool (26 individual toggles would overwhelm Settings) but finer than the single
/// `dataConsent` switch that, until now, was the only lever — all-or-nothing across every tool. Sits
/// BELOW `dataConsent`, never instead of it: `dataConsent` remains the master switch for context
/// building, the daily brief, proactive nudges and `MemoryMaintainer`; a `CoachPurpose` only narrows what
/// tools are offered/allowed once that master switch is already on.
enum CoachPurpose: String, Codable, CaseIterable, Identifiable {
    case coreBiometrics, longHistory, workouts, planning, stress, logs, sensitiveLogs, memory, patterns

    var id: String { rawValue }
}

/// The simple privacy choices presented to most people. Fine-grained purposes stay intact underneath,
/// but a person should not have to understand every data path just to start using Coach.
enum CoachDataAccessMode: String, CaseIterable, Identifiable {
    case essentials, personal, deepInsights, expert

    var id: String { rawValue }

    var purposes: Set<CoachPurpose>? {
        switch self {
        case .essentials:
            return [.coreBiometrics, .workouts, .planning, .memory]
        case .personal:
            return [.coreBiometrics, .workouts, .planning, .stress, .logs, .memory, .patterns]
        case .deepInsights:
            // Sensitive journal labels intentionally remain OFF even here: they need a conscious
            // separate choice in Expert settings rather than riding a broad convenience preset.
            return [.coreBiometrics, .longHistory, .workouts, .planning, .stress, .logs, .memory, .patterns]
        case .expert:
            return nil
        }
    }

    static func current(for enabled: Set<CoachPurpose>) -> CoachDataAccessMode {
        for mode in [CoachDataAccessMode.essentials, .personal, .deepInsights] where mode.purposes == enabled {
            return mode
        }
        return .expert
    }
}

extension CoachTool {
    /// Which purpose group gates this tool. An exhaustive switch on `CoachPurpose` (not `default:`), so
    /// a new `CoachTool` case that isn't added here is a compile error — a new tool can never silently
    /// ship without being consent-gated.
    var purpose: CoachPurpose {
        switch self {
        case .biometricSummary, .readiness, .chargeDrivers, .sleepDetail, .plotMetric:
            return .coreBiometrics
        case .dataCatalog, .metricHistory:
            return .longHistory
        case .recentWorkouts, .zoneMinutes, .sessionOutlook, .simulateDay, .estimateSessionEffort:
            return .workouts
        case .proposePlan, .proposeGoalSetup, .planAdherence, .rangeReport:
            return .planning
        case .stressIndex:
            return .stress
        case .myLogs, .logCaffeine, .logJournal, .logLabMarker:
            return .logs
        case .sensitiveLogs:
            return .sensitiveLogs
        case .rememberFact, .updateFact, .forgetFact, .searchPastConversations:
            return .memory
        case .personalPatterns, .trainingPreferences:
            return .patterns
        }
    }
}

/// Which purpose groups the user has granted, layered UNDER `dataConsent`. Persisted as JSON-encoded raw
/// values in UserDefaults, like the rest of the coach's settings.
struct ToolConsent: Codable, Equatable {
    var enabled: Set<CoachPurpose>

    func allows(_ tool: CoachTool) -> Bool { enabled.contains(tool.purpose) }

    private static let key = "ai.toolConsent"

    /// Whether a `ToolConsent` has ever actually been saved — as opposed to `load()` having produced one
    /// from the legacy-key migration. Lets a caller distinguish "never touched yet" (still fine to
    /// re-derive from `dataConsent`) from "the user has explicitly configured this" (never overwrite).
    static func hasBeenExplicitlySaved(defaults: UserDefaults = .standard) -> Bool {
        defaults.data(forKey: key) != nil
    }

    /// Load the persisted consent, migrating from the legacy `dataConsent`/`includeOnDeviceSignals` bools
    /// on first read if nothing has been saved yet.
    ///
    /// `dataConsent == true` grants the four conversational essentials — core biometrics, workouts,
    /// planning, memory — the load-bearing part of what the old all-or-nothing switch covered day to day.
    /// `longHistory`, `stress` and `logs` start OFF even for an existing `dataConsent` user: a deliberate, narrower
    /// default under the new granular model, not an oversight — re-enabling any is one tap in Data
    /// access. `includeOnDeviceSignals == true` (the old second opt-in) additionally grants `patterns`
    /// (what it always meant) and `logs` (its own description already named "Lab Book markers", which
    /// `logs` now covers).
    ///
    /// Reads the legacy keys directly by their literal string (not `AICoachEngine`'s private constants —
    /// this type doesn't have access to them) since they're a stable, historical migration source, not a
    /// live API. The legacy keys are left in place afterwards (not deleted), so a rollback to an older
    /// build still finds its old settings.
    static func load(defaults: UserDefaults = .standard) -> ToolConsent {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ToolConsent.self, from: data) {
            return decoded
        }
        var enabled: Set<CoachPurpose> = []
        if defaults.bool(forKey: "ai.dataConsent") {
            enabled.formUnion([.coreBiometrics, .workouts, .planning, .memory])
        }
        if defaults.bool(forKey: "ai.includeOnDeviceSignals") {
            enabled.formUnion([.patterns, .logs])
        }
        return ToolConsent(enabled: enabled)
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
