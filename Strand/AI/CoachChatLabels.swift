import Foundation

/// The words the coach chat puts beside a reply, shared by the iOS chat (`CoachView`) and the Android one through
/// the core, so the two never word the same evidence or the same unprompted message differently. English source
/// strings: each screen translates them through the app's catalogue.
extension CoachTool {
    /// What this tool read, as the reply's evidence chain names it.
    var evidenceTitle: String {
        switch self {
        case .dataCatalog: return "Data catalog"
        case .biometricSummary: return "Your metrics"
        case .recentWorkouts: return "Recent workouts"
        case .strengthHistory: return "Strength history"
        case .bodyMetrics: return "Body & energy"
        case .stressIndex: return "Stress index"
        case .personalPatterns: return "Your patterns"
        case .plotMetric: return "Chart"
        case .rememberFact, .updateFact, .forgetFact: return "Memory"
        case .searchPastConversations: return "Past conversations"
        case .logCaffeine: return "Caffeine log"
        case .logJournal: return "Journal"
        case .logLabMarker: return "Lab Book"
        case .logWeight: return "Weigh-in"
        case .energyBalance: return "Energy"
        case .sleepDetail: return "Sleep detail"
        case .rangeReport: return "Range report"
        case .trainingPreferences: return "Training preferences"
        case .metricHistory: return "Long-term trend"
        case .readiness: return "Readiness"
        case .chargeDrivers: return "Charge breakdown"
        case .proposePlan: return "Plan proposal"
        case .proposeGoalSetup: return "Goal and routine draft"
        case .showCard: return "A card from your data"
        case .findHevyExercises: return "Your exercise list"
        case .hevyRoutines: return "Your routines"
        case .proposeHevyRoutine: return "Routine draft"
        case .proposeHevyWorkout: return "Workout draft"
        case .sessionOutlook: return "Session outlook"
        case .simulateDay: return "Simulation"
        case .planAdherence: return "Plan adherence"
        case .myLogs: return "Your logs"
        case .sensitiveLogs: return "Sensitive journal"
        case .zoneMinutes: return "Zone minutes"
        case .trainingLoad: return "Training load"
        case .estimateSessionEffort: return "Session Effort estimate"
        }
    }
}

extension ChatMessage.Origin {
    /// The line over a message the coach started, nil for a reply.
    var gotInTouchLine: String? {
        switch self {
        case .brief:        return "Your daily brief — the coach got in touch"
        case .checkIn:      return "Check-in — the coach got in touch"
        case .nudge:        return "The coach got in touch"
        case .weeklyReview: return "Your weekly review — the coach got in touch"
        case .reply:        return nil
        }
    }
}
