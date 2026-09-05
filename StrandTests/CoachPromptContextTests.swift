import XCTest
@testable import Strand

/// Pins the contextual suggestion chips.
///
/// A static list is wrong most of the time in a specific way: it offers "Analyse my sleep" to someone
/// who has not worn the strap, and "What should today's training look like?" at ten at night after they
/// already trained. These tests hold the two properties that make a chosen list better than a fixed
/// one — that the choice tracks what actually happened, and that a sparse context still gets four
/// sensible questions rather than a half-empty row.
final class CoachPromptContextTests: XCTestCase {

    // MARK: - Nothing known

    /// A fresh install with nothing synced sees exactly the standing list. The contextual path must not
    /// make the no-data case worse than it was.
    func testAnEmptyContextGivesTheStandingList() {
        XCTAssertEqual(CoachPrompts.suggestions(for: CoachPrompts.Context()),
                       CoachPrompts.suggestions)
    }

    /// The row is always full, whatever the context. Four chips is the design; three is a layout that
    /// looks broken.
    func testTheRowIsAlwaysFull() {
        var context = CoachPrompts.Context()
        context.trainedToday = true
        XCTAssertEqual(CoachPrompts.suggestions(for: context).count, CoachPrompts.maxSuggestions)
        context.hevyConnected = true
        context.hasSleepLastNight = true
        context.hasPendingDraft = true
        XCTAssertEqual(CoachPrompts.suggestions(for: context).count, CoachPrompts.maxSuggestions)
    }

    /// No duplicates, whatever combination fires. A chip offered twice reads as a bug in the answer,
    /// not in the row.
    func testNoSuggestionAppearsTwice() {
        var context = CoachPrompts.Context()
        context.trainedToday = true
        context.strengthToday = true
        context.hevyConnected = true
        context.hasSleepLastNight = true
        context.hasPendingDraft = true
        context.chargeToday = 30
        context.chargeBaseline = 60
        let out = CoachPrompts.suggestions(for: context)
        XCTAssertEqual(Set(out).count, out.count)
    }

    // MARK: - What just happened comes first

    func testASessionTodayLeadsTheRow() throws {
        var context = CoachPrompts.Context()
        context.trainedToday = true
        let first = try XCTUnwrap(CoachPrompts.suggestions(for: context).first)
        XCTAssertTrue(first.lowercased().contains("training"), first)
    }

    /// A waiting draft is surfaced as a question rather than only as a badge — gentler, and it gets the
    /// same thing looked at.
    func testAPendingDraftIsOffered() {
        var context = CoachPrompts.Context()
        context.hasPendingDraft = true
        XCTAssertTrue(CoachPrompts.suggestions(for: context)
            .contains { $0.lowercased().contains("draft") })
    }

    // MARK: - "Low" means low FOR THIS PERSON

    /// THE test that stops a fixed threshold creeping back in. Someone who lives at 45 must not be
    /// asked why their charge is low every single morning.
    func testALowButNormalChargeIsNotFlagged() {
        var context = CoachPrompts.Context()
        context.chargeToday = 45
        context.chargeBaseline = 47
        XCTAssertFalse(CoachPrompts.suggestions(for: context)
            .contains { $0.lowercased().contains("charge low") },
            "45 is this person's normal — asking every day teaches them to ignore the row")
    }

    /// And a genuine drop against their own average IS offered, even at a number that would look fine
    /// on an absolute scale.
    func testADropAgainstTheirOwnAverageIsOffered() {
        var context = CoachPrompts.Context()
        context.chargeToday = 62
        context.chargeBaseline = 80
        XCTAssertTrue(CoachPrompts.suggestions(for: context)
            .contains { $0.lowercased().contains("charge low") },
            "62 against an average of 80 is a real drop, even though 62 sounds healthy")
    }

    /// Without a baseline there is nothing to compare against, and the chip is not offered — rather
    /// than falling back to a fixed number nobody chose.
    func testNoBaselineMeansNoChargeChip() {
        var context = CoachPrompts.Context()
        context.chargeToday = 20
        XCTAssertFalse(CoachPrompts.suggestions(for: context)
            .contains { $0.lowercased().contains("charge low") })
    }

    // MARK: - Only offer what can be answered

    /// Strength questions appear only when Hevy is connected. Offering "Show me my strength progress"
    /// to someone with no strength data is a shortcut to a disappointing answer.
    func testStrengthPromptsNeedHevy() {
        var context = CoachPrompts.Context()
        context.strengthToday = true
        XCTAssertFalse(CoachPrompts.suggestions(for: context)
            .contains { $0.lowercased().contains("strength progress") })

        context.hevyConnected = true
        XCTAssertTrue(CoachPrompts.suggestions(for: context)
            .contains { $0.lowercased().contains("strength progress") })
    }

    /// "What should I train today?" is not offered to someone who already trained today.
    func testTheTrainTodayPromptIsDroppedAfterASession() {
        var context = CoachPrompts.Context()
        context.hevyConnected = true
        XCTAssertTrue(CoachPrompts.suggestions(for: context)
            .contains { $0.lowercased().contains("what should i train") })

        context.strengthToday = true
        XCTAssertFalse(CoachPrompts.suggestions(for: context)
            .contains { $0.lowercased().contains("what should i train") })
    }

    // MARK: - Determinism

    /// The same context always produces the same row. A shortcut that reshuffles between renders is
    /// one nobody can learn.
    func testTheSelectionIsDeterministic() {
        var context = CoachPrompts.Context()
        context.hevyConnected = true
        context.hasSleepLastNight = true
        let a = CoachPrompts.suggestions(for: context)
        let b = CoachPrompts.suggestions(for: context)
        XCTAssertEqual(a, b)
    }
}
