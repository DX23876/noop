import XCTest
@testable import Strand

/// Pins P13's promise (7.5): the three coaching styles are BEHAVIOURALLY different — a decision lean, a
/// strictness, a focus — not just three tones of the same coach. Pure over `CoachPersona`.
///
/// #R9 note: the persona is now the STYLE only ("how"); the coach's NAME comes from its identity
/// (`CoachIdentity`, the "who" axis), so the persona preambles deliberately no longer claim a name.
final class CoachPersonaBehaviourTests: XCTestCase {

    // MARK: - 7.4 / R9: style describes itself, and does NOT claim a coach name

    func testEachPersonaDescribesItsStyleWithoutClaimingAName() {
        XCTAssertTrue(CoachPersona.guardian.systemPreamble.contains("COACHING STYLE"))
        XCTAssertTrue(CoachPersona.commander.systemPreamble.contains("COACHING STYLE"))
        // The name is the identity's job now — the persona must not hard-claim one, or it fights the
        // identity clause that leads the prompt (#R9).
        for p in CoachPersona.allCases {
            XCTAssertFalse(p.systemPreamble.contains("You are \(p.title)"),
                           "\(p.title)'s style preamble must not claim to BE the coach's name")
        }
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
