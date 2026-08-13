import XCTest
@testable import Strand

/// The guided goal wizard's step machine (#coach-bugs).
///
/// These tests exist because the bug they guard against was invisible to every other kind of test: the
/// wizard kept its step in SwiftUI `@State`, so a re-created view silently threw the user back to "Let's
/// set a goal" mid-setup. Moving the state into `GoalOnboardingDraft` is what makes the flow resumable —
/// and testable at all, with no view, no store and no strap.
@MainActor
final class GoalOnboardingDraftTests: XCTestCase {

    private func freshDraft() -> GoalOnboardingDraft {
        let d = GoalOnboardingDraft()
        d.reset()
        return d
    }

    // MARK: - Steps

    func testStartsOnWelcome() {
        XCTAssertEqual(freshDraft().step, .welcome)
    }

    func testAdvancesThroughEveryStepInOrder() {
        let d = freshDraft()
        XCTAssertTrue(d.advance()); XCTAssertEqual(d.step, .type)
        d.title = "Run 5k"
        XCTAssertTrue(d.advance()); XCTAssertEqual(d.step, .details)
        XCTAssertTrue(d.advance()); XCTAssertEqual(d.step, .why)
        XCTAssertTrue(d.advance()); XCTAssertEqual(d.step, .confirm)
    }

    func testCannotAdvancePastConfirm() {
        let d = freshDraft()
        d.step = .confirm
        XCTAssertFalse(d.advance())
        XCTAssertEqual(d.step, .confirm)
    }

    func testCannotGoBackFromWelcome() {
        let d = freshDraft()
        XCTAssertFalse(d.back())
        XCTAssertEqual(d.step, .welcome)
    }

    // MARK: - The details gate

    func testDetailsStepRefusesToAdvanceWithoutATitle() {
        let d = freshDraft()
        d.step = .details
        XCTAssertFalse(d.canAdvance)
        XCTAssertFalse(d.advance())
        XCTAssertEqual(d.step, .details, "an empty title must hold the flow, not skip the step")
    }

    func testWhitespaceOnlyTitleDoesNotSatisfyTheGate() {
        let d = freshDraft()
        d.step = .details
        d.title = "   "
        XCTAssertFalse(d.canAdvance)
    }

    func testTitledDetailsStepAdvances() {
        let d = freshDraft()
        d.step = .details
        d.title = "Run 5k without stopping"
        XCTAssertTrue(d.advance())
        XCTAssertEqual(d.step, .why)
    }

    // MARK: - Resumability (the actual bug)

    /// The loop, expressed as a test: entering details and then having the VIEW rebuilt must leave the
    /// wizard exactly where it was. Since the state no longer lives in the view, "rebuilding the view" is
    /// simply reading the shared draft again.
    func testDraftSurvivesAViewRebuild() {
        let shared = GoalOnboardingDraft.shared
        shared.reset()
        shared.kind = .strength
        _ = shared.advance()                       // welcome -> type
        _ = shared.advance()                       // type -> details
        shared.title = "Get back to full-body work"
        shared.targetText = "3"

        // What a re-created CoachGoalOnboardingFlow reads.
        let afterRebuild = GoalOnboardingDraft.shared
        XCTAssertEqual(afterRebuild.step, .details)
        XCTAssertEqual(afterRebuild.title, "Get back to full-body work")
        XCTAssertEqual(afterRebuild.kind, .strength)
        shared.reset()
    }

    // MARK: - isActive gates the one-time offer

    func testFreshDraftIsNotActive() {
        XCTAssertFalse(freshDraft().isActive)
    }

    func testDraftPastWelcomeIsActive() {
        let d = freshDraft()
        _ = d.advance()
        XCTAssertTrue(d.isActive, "a setup in progress must block the one-time onboarding offer")
    }

    func testTypedTitleAloneMakesTheDraftActive() {
        let d = freshDraft()
        d.title = "Something"
        XCTAssertTrue(d.isActive)
    }

    // MARK: - Reset

    func testResetClearsEveryFieldAndReturnsToWelcome() {
        let d = freshDraft()
        d.kind = .weight
        d.title = "Get to 78 kg"
        d.baselineText = "82"
        d.targetText = "78"
        d.hasTargetDate = true
        d.motivation = "hill running"
        d.shareMotivation = true
        d.motivationTags = [CoachGoal.MotivationTag.allCases[0]]
        d.reason = "deliberate cut"
        d.step = .confirm

        d.reset()

        XCTAssertEqual(d.step, .welcome)
        XCTAssertEqual(d.kind, .run)
        XCTAssertTrue(d.title.isEmpty)
        XCTAssertTrue(d.baselineText.isEmpty)
        XCTAssertTrue(d.targetText.isEmpty)
        // A fresh wizard starts on `.run`, which IS measurable, so the target date is pre-armed —
        // and the "user touched it" memory is cleared with everything else.
        XCTAssertTrue(d.hasTargetDate)
        XCTAssertFalse(d.targetDateTouched)
        XCTAssertTrue(d.motivation.isEmpty)
        XCTAssertFalse(d.shareMotivation)
        XCTAssertTrue(d.motivationTags.isEmpty)
        XCTAssertTrue(d.reason.isEmpty)
        XCTAssertFalse(d.isActive)
    }

    // MARK: - The drafted goal

    func testGoalCarriesTheTypedNumbersAndAcceptsACommaDecimal() {
        let d = freshDraft()
        d.kind = .weight
        d.title = "Get to 78 kg"
        d.baselineText = "82,5"
        d.targetText = "78"
        let goal = d.goal
        XCTAssertEqual(goal.kind, .weight)
        XCTAssertEqual(goal.title, "Get to 78 kg")
        XCTAssertEqual(goal.baseline ?? 0, 82.5, accuracy: 0.0001)
        XCTAssertEqual(goal.target ?? 0, 78, accuracy: 0.0001)
    }

    func testTargetDateFollowsTheToggleBothWays() {
        let d = freshDraft()
        d.title = "Run 5k"
        XCTAssertNotNil(d.goal.targetDate, "a measurable kind arrives with a date already armed")
        d.hasTargetDate = false
        XCTAssertNil(d.goal.targetDate)
    }

    // MARK: - Target-date default (the route hangs off it)

    func testMeasurableKindArmsTheTargetDateAndAHeldKindDoesNot() {
        let d = freshDraft()
        d.kindChanged(to: .weight)
        XCTAssertTrue(d.hasTargetDate)
        d.kindChanged(to: .custom)
        XCTAssertFalse(d.hasTargetDate, "NOOP has no number to pace a held goal against")
        d.kindChanged(to: .sleep)
        XCTAssertTrue(d.hasTargetDate)
    }

    func testKindStopsOverridingTheSwitchOnceTheUserTouchesIt() {
        let d = freshDraft()
        d.hasTargetDate = false
        d.targetDateTouched = true
        d.kindChanged(to: .weight)
        XCTAssertFalse(d.hasTargetDate, "the user's own choice must outlive a kind change")
    }

    // MARK: - The from/to gate (a goal that could never show progress)

    func testDetailsStepRefusesAnIdenticalFromAndTo() {
        let d = freshDraft()
        d.step = .details
        d.kind = .weight
        d.title = "Get to 78 kg"
        d.baselineText = "78"
        d.targetText = "78"
        XCTAssertFalse(d.canAdvance)
        XCTAssertFalse(d.advance())
        XCTAssertEqual(d.step, .details)
    }

    /// Comma decimals are parsed the same way the drafted goal parses them, so "78,0" and "78" are
    /// recognised as one and the same number rather than slipping past as different strings.
    func testIdenticalFromAndToIsCaughtAcrossDecimalSeparators() {
        XCTAssertFalse(CoachGoalRange.isUsable(kind: .weight, baselineText: "78,0", targetText: "78"))
        XCTAssertTrue(CoachGoalRange.isUsable(kind: .weight, baselineText: "82,5", targetText: "78"))
    }

    /// A half-filled range is ordinary work in progress, and a held kind has no range at all — neither
    /// is refused.
    func testPartialOrUnquantifiedRangesAreNotRefused() {
        XCTAssertTrue(CoachGoalRange.isUsable(kind: .weight, baselineText: "78", targetText: ""))
        XCTAssertTrue(CoachGoalRange.isUsable(kind: .weight, baselineText: "", targetText: ""))
        XCTAssertTrue(CoachGoalRange.isUsable(kind: .custom, baselineText: "3", targetText: "3"))
    }

    func testDifferentFromAndToAdvances() {
        let d = freshDraft()
        d.step = .details
        d.kind = .weight
        d.title = "Get to 78 kg"
        d.baselineText = "82"
        d.targetText = "78"
        XCTAssertTrue(d.advance())
        XCTAssertEqual(d.step, .why)
    }

    func testMotivationTagTogglesOnAndOff() {
        let d = freshDraft()
        let tag = CoachGoal.MotivationTag.allCases[0]
        d.toggleMotivationTag(tag)
        XCTAssertTrue(d.motivationTags.contains(tag))
        d.toggleMotivationTag(tag)
        XCTAssertFalse(d.motivationTags.contains(tag))
    }
}
