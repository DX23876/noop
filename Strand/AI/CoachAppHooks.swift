import Foundation

/// What the coach reads from or tells the app around it, beyond the wearer's data (`CoachDataReading`): the goal
/// tracking state, the coach's chosen identity, and the notifications a plan or a proactive signal posts. Each
/// target that links the coach defines `coachAppHooks()` (`CoachAppHooks+App.swift` on Apple), so `AICoach`
/// names no app store or notifier (Android parity plan, Coach extraction).
@MainActor
protocol CoachAppHooks {
    var goalTracking: GoalTrackingModel { get }
    /// The identity line that opens the system prompt (`CoachIdentity.identityPreamble`).
    var identityPreamble: String { get }
    func planProposed(_ proposal: PlanProposal)
    func proactiveSignal(_ signal: ProactiveSignal, level: ProactiveLevel)
}
