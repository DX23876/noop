import XCTest
@testable import Strand

/// Pins P13's promise (7.5): the three coaching styles are BEHAVIOURALLY different — a decision lean, a
/// strictness, a focus — not just three tones of the same coach; and (7.4) each preamble carries the
/// coach's own identity so its self-reference matches the chosen style. Pure over `CoachPersona`.
final class CoachPersonaBehaviourTests: XCTestCase {

    // MARK: - 7.4: identity

    func testEachPersonaNamesItselfInTheFirstLine() {
        XCTAssertTrue(CoachPersona.guardian.systemPreamble.contains("You are Guardian"))
        XCTAssertTrue(CoachPersona.friend.systemPreamble.contains("You are Friend"))
        XCTAssertTrue(CoachPersona.commander.systemPreamble.contains("You are Commander"))
    }

    // MARK: - 7.5: distinct DECISION LEAN on an ambiguous readiness call

    /// Guardian leans to rest, Commander pushes (within guardrails), Friend hands the choice back — the
    /// single most load-bearing behavioural difference, so pin it explicitly.
    func testAmbiguousReadinessLeanDiffersByPersona() {
        XCTAssertTrue(CoachPersona.guardian.systemPreamble.lowercased().contains("lean toward rest"))
        XCTAssertTrue(CoachPersona.commander.systemPreamble.lowercased().contains("push for progression"))
        XCTAssertTrue(CoachPersona.friend.systemPreamble.lowercased().contains("let them choose"))
    }

    // MARK: - 7.5: every persona still respects the safety guardrails

    /// Behavioural distinctiveness must NOT cost the recovery guardrails — Commander pushes but is still
    /// pinned to the readiness data, so no style becomes reckless.
    func testCommanderStillRespectsTheGuardrails() {
        let p = CoachPersona.commander.systemPreamble.lowercased()
        XCTAssertTrue(p.contains("never") && p.contains("guardrail"),
                      "the demanding style must still be nailed to the recovery guardrails")
    }

    // MARK: - 7.5: the three are genuinely different strings

    func testThePreamblesAreAllDistinct() {
        let all = CoachPersona.allCases.map(\.systemPreamble)
        XCTAssertEqual(Set(all).count, all.count, "no two personas may share a preamble")
        // And the subtitles hint at behaviour, not just tone.
        XCTAssertTrue(CoachPersona.guardian.subtitle.lowercased().contains("rest"))
        XCTAssertTrue(CoachPersona.commander.subtitle.lowercased().contains("holds you"))
    }
}
