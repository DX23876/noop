import XCTest
@testable import Strand

/// Pins the #268 Effort scale at the coach-plan boundary.
///
/// A proposed session carries `targetEffort` on NOOP's canonical 0–100 axis — that is what the coach's
/// tool schema accepts ("target_effort … 0–100"), what its day context describes ("effort(0-100)") and
/// what `EffortFeasibility` computes. The WHOOP 0–21 setting is display-only. The plan surfaces printed
/// that stored number verbatim, so a wearer on the 0–21 axis read "target effort 63" for a session their
/// own Effort rings could only ever show as 13.2 — a number that axis cannot produce at all.
///
/// The two audiences are therefore split by NAME (`summary(effortScale:)` vs `contextSummary()`) rather
/// than by a defaulted argument, so neither can be reached by forgetting one. These tests hold that line:
/// the user's string converts, the model's string must NOT.
@MainActor
final class PlanProposalEffortScaleTests: XCTestCase {

    private func proposal(effort: Double?) -> PlanProposal {
        PlanProposal(day: "2026-09-03", sport: "Cycling", intent: .easy,
                     targetEffort: effort, zone: 2, durationMin: 45,
                     rationale: "Zone 2 base")
    }

    // MARK: - The user's string converts

    func testUserSummaryKeepsTheNativeAxisOnTheHundredScale() {
        let s = proposal(effort: 63).summary(effortScale: .hundred)
        XCTAssertTrue(s.contains("63/100"), s)
    }

    /// THE regression: 63 on the canonical axis is 13.2 on WHOOP's, and the string must say so.
    func testUserSummaryConvertsToTheWhoopAxis() {
        let s = proposal(effort: 63).summary(effortScale: .whoop)
        XCTAssertTrue(s.contains("13.2/21"), s)
        XCTAssertFalse(s.contains("63"), "the unconverted number must not survive into the copy: \(s)")
    }

    /// The axis rides along with the number. In a one-line summary there is no ring or "of N" caption
    /// beside it to read the figure against, so a bare "13.2" is ambiguous between the two scales.
    func testUserSummaryAlwaysNamesTheAxis() {
        for scale in [EffortScale.hundred, .whoop] {
            let s = proposal(effort: 40).summary(effortScale: scale)
            XCTAssertTrue(s.contains("/\(UnitFormatter.effortScaleMax(scale))"),
                          "\(scale) summary must carry its denominator: \(s)")
        }
    }

    /// A proposal with no target says nothing about Effort — on either scale. Inventing a "0/21" here
    /// would state a target the coach never set.
    func testNoTargetPrintsNoEffortClause() {
        for scale in [EffortScale.hundred, .whoop] {
            let s = proposal(effort: nil).summary(effortScale: scale)
            XCTAssertFalse(s.lowercased().contains("effort"), s)
        }
    }

    /// Everything that is not the Effort figure is identical on both axes — the conversion must not
    /// disturb sport, intent, duration or zone.
    func testOnlyTheEffortFigureDiffersBetweenScales() {
        let hundred = proposal(effort: 63).summary(effortScale: .hundred)
        let whoop = proposal(effort: 63).summary(effortScale: .whoop)
        let stem = { (s: String) in s.components(separatedBy: ", target effort").first ?? s }
        XCTAssertEqual(stem(hundred), stem(whoop))
        XCTAssertTrue(stem(hundred).contains("45 min"), hundred)
        XCTAssertTrue(stem(hundred).contains("Zone 2"), hundred)
    }

    // MARK: - The model's string must NOT convert

    /// Rendering the wearer's display axis into the model's context would feed the coach numbers on a
    /// scale its own tools cannot accept — it would read 13.2, then pass 13.2 back as a 0–100 target and
    /// propose a near-rest session while believing it had asked for a hard one.
    func testContextSummaryStaysOnTheCanonicalAxis() {
        let s = proposal(effort: 63).contextSummary()
        XCTAssertTrue(s.contains("63"), s)
        XCTAssertFalse(s.contains("13.2"), s)
        XCTAssertFalse(s.contains("/21"), s)
    }

    /// The context string is scale-BLIND, not scale-aware-with-a-default: it must read identically no
    /// matter what the wearer has chosen, because the user default is irrelevant to it.
    func testContextSummaryIsUnaffectedByTheUserSetting() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: UnitPrefs.effortScaleKey)
        defer {
            if let saved { defaults.set(saved, forKey: UnitPrefs.effortScaleKey) }
            else { defaults.removeObject(forKey: UnitPrefs.effortScaleKey) }
        }
        defaults.set(EffortScale.whoop.rawValue, forKey: UnitPrefs.effortScaleKey)
        XCTAssertEqual(UnitPrefs.currentEffortScale(), .whoop, "precondition: the setting is on 0–21")
        XCTAssertTrue(proposal(effort: 63).contextSummary().contains("63"),
                      "the model's view of a target must not follow a display preference")
    }

    // MARK: - The shared formatter

    func testEffortWithScaleFollowsTheAppWideDecimalConvention() {
        // Whole numbers on 0–100 so Effort matches Charge and Rest; one decimal on the compressed axis.
        XCTAssertEqual(UnitFormatter.effortWithScale(63, scale: .hundred), "63/100")
        XCTAssertEqual(UnitFormatter.effortWithScale(63.4, scale: .hundred), "63/100")
        XCTAssertEqual(UnitFormatter.effortWithScale(63, scale: .whoop), "13.2/21")
        XCTAssertEqual(UnitFormatter.effortWithScale(0, scale: .whoop), "0.0/21")
        XCTAssertEqual(UnitFormatter.effortWithScale(100, scale: .whoop), "21.0/21")
    }

    /// The conversion is the shipped one, not a second copy of the factor.
    func testEffortWithScaleAgreesWithTheSharedConversion() {
        for v in stride(from: 0.0, through: 100.0, by: 7.5) {
            let expected = UnitFormatter.effortValue(v, scale: .whoop)
            let text = UnitFormatter.effortWithScale(v, scale: .whoop)
            let shown = Double(text.components(separatedBy: "/").first ?? "")
            // One-decimal rounding is at most half a tenth out, and a value landing exactly on the
            // boundary (3.15 → "3.2") sits AT 0.05 — so the tolerance has to be just past it, not on it.
            XCTAssertEqual(try XCTUnwrap(shown), expected, accuracy: 0.0501, text)
        }
    }
}

/// Pins the Effort-axis instruction the coach's context carries.
///
/// The structured half of #268 is enforced by types (`summary(effortScale:)` vs `contextSummary()`).
/// Prose cannot be: the model writes it. So this holds the two properties that ARE ours to guarantee —
/// that the note appears exactly when there is something to convert, and that it never tells the model
/// to move its INPUTS or its tool arguments off the canonical 0–100 axis, which would have it pass a
/// 0–21 figure into a 0–100 parameter.
@MainActor
final class CoachEffortAxisNoteTests: XCTestCase {

    /// The default axis needs no note: the conversion is the identity, so emitting one would be pure
    /// tokens — and it keeps every existing install's context byte-identical.
    func testNativeAxisEmitsNoNote() {
        XCTAssertNil(AICoachEngine.effortAxisNote(scale: .hundred))
    }

    func testWhoopAxisEmitsANote() throws {
        let note = try XCTUnwrap(AICoachEngine.effortAxisNote(scale: .whoop))
        XCTAssertTrue(note.contains("21"), note)
    }

    /// The note must carry a WORKED example, not just a rule — and it has to be the one the structured
    /// summary would produce, or the coach's prose and its own plan cards would disagree.
    func testNoteCarriesTheSameWorkedExampleTheSummaryWouldPrint() throws {
        let note = try XCTUnwrap(AICoachEngine.effortAxisNote(scale: .whoop))
        XCTAssertTrue(note.contains(UnitFormatter.effortWithScale(63, scale: .whoop)), note)
    }

    /// THE guard on the instruction: inputs and tool arguments stay canonical. A note that told the model
    /// to convert everything would make it call `target_effort` with a 0–21 number, and a "hard session"
    /// would be filed as near-rest.
    func testNoteKeepsToolsAndInputsOnTheCanonicalAxis() throws {
        let note = try XCTUnwrap(AICoachEngine.effortAxisNote(scale: .whoop))
        XCTAssertTrue(note.contains("target_effort"), "the tool parameter must be named explicitly: \(note)")
        XCTAssertTrue(note.contains("0–100"), note)
        XCTAssertTrue(note.lowercased().contains("must stay there"), note)
    }
}
