import Foundation

/// The guided goal-setup wizard's state, held OUTSIDE the view that draws it.
///
/// Why this exists: `CoachGoalOnboardingFlow` used to keep its step and every field in `@State`. SwiftUI
/// `@State` is tied to view identity, so any re-creation of that view — and the flow is presented from a
/// screen that can itself be inside a sheet — silently reset `step` to `.welcome`, throwing the user back
/// to "Let's set a goal" with their details gone. That's the reported loop: not a navigation bug the user
/// could work around, but state loss wearing navigation's clothes.
///
/// Holding the wizard here makes a re-created view RESUME instead of restart, and turns the step machine
/// into something testable with no UI at all. The instance is shared (there is only ever one goal being
/// set up at a time) and explicitly `reset()` when the flow closes either way, so a finished goal never
/// leaks into the next one.
@MainActor
final class GoalOnboardingDraft: ObservableObject {

    /// One question at a time — welcome → type → details → why → confirm.
    enum Step: Int, CaseIterable {
        case welcome, type, details, why, confirm

        var title: String {
            switch self {
            case .welcome: return "Let's set a goal"
            case .type:    return "What kind of goal?"
            case .details: return "The details"
            case .why:     return "Why does it matter?"
            case .confirm: return "Ready?"
            }
        }
    }

    static let shared = GoalOnboardingDraft()

    @Published var step: Step = .welcome

    // The same draft fields as the one-page editor.
    @Published var kind: CoachGoal.Kind = .run
    @Published var title = ""
    @Published var baselineText = ""
    @Published var targetText = ""
    @Published var hasTargetDate = false
    @Published var targetDate = Date().addingTimeInterval(60 * 24 * 3600)
    @Published var motivation = ""
    @Published var motivationTags: Set<CoachGoal.MotivationTag> = []
    @Published var shareMotivation = false
    /// The user's own words on why they're taking a brisk pace, captured by the safety gate's prompt.
    @Published var reason = ""

    /// True once the user has moved past the welcome screen or typed anything — i.e. there is real work
    /// in here worth resuming. `CoachView`'s one-time goal-onboarding offer checks this so it can never
    /// throw up a second copy of this flow over a setup already in progress.
    var isActive: Bool {
        step != .welcome || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the current step lets the user move on. Only "details" gates (it needs a title); every
    /// other step is a free choice or optional.
    var canAdvance: Bool {
        step != .details || !trimmedTitle.isEmpty
    }

    /// The goal as currently drafted — the exact value `CoachGoalStore.commit` receives, so what the
    /// confirm step previews and what gets saved can never disagree.
    var goal: CoachGoal {
        CoachGoal(kind: kind, title: title,
                  baseline: Double(baselineText.replacingOccurrences(of: ",", with: ".")),
                  target: Double(targetText.replacingOccurrences(of: ",", with: ".")),
                  targetDate: hasTargetDate ? targetDate : nil,
                  motivation: motivation,
                  motivationTags: CoachGoal.MotivationTag.allCases.filter { motivationTags.contains($0) },
                  shareMotivation: shareMotivation)
    }

    // MARK: - Navigation

    /// Advance one step, refusing when the current step isn't satisfied. Returns whether it moved, so a
    /// test can pin the gate without going through the view.
    @discardableResult
    func advance() -> Bool {
        guard canAdvance, let next = Step(rawValue: step.rawValue + 1) else { return false }
        step = next
        return true
    }

    @discardableResult
    func back() -> Bool {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return false }
        step = prev
        return true
    }

    func toggleMotivationTag(_ tag: CoachGoal.MotivationTag) {
        if motivationTags.contains(tag) { motivationTags.remove(tag) } else { motivationTags.insert(tag) }
    }

    /// Clear everything back to a fresh wizard. Called when the flow closes — saved or skipped — so the
    /// next "Add another goal" starts blank rather than inside someone else's half-finished goal.
    func reset() {
        step = .welcome
        kind = .run
        title = ""
        baselineText = ""
        targetText = ""
        hasTargetDate = false
        targetDate = Date().addingTimeInterval(60 * 24 * 3600)
        motivation = ""
        motivationTags = []
        shareMotivation = false
        reason = ""
    }
}
