import XCTest
@testable import Strand

/// Pins the shape of the pass that settles an outstanding re-score debt (#1538).
///
/// Reported from a real device: a manual 21-day reanalysis completed and the scores appeared; the app was
/// reopened a while later and was immediately re-analysing all 21 days again, sluggish, with no app update
/// in between.
///
/// The mechanism, and why it repeats rather than happening once:
///
///  1. The strap offloads while the app is backgrounded — the normal case, it runs as a bluetooth-central.
///  2. `RescoreBackgroundPolicy.decide` defers, because the last completed pass on this library took
///     longer than `backgroundBudgetSeconds`. Deferring records a debt.
///  3. The next foreground entry calls `runDeferredRescoreIfOwed`, which took `analyzeRecent()`'s
///     DEFAULTS — including `allowDayReuse: false`. So instead of the cheap fingerprint-gated pass the
///     deferral stood in for, it re-derived the whole window from raw.
///  4. That long pass re-confirms `lastCompletedPassSeconds` as over budget, so the next background
///     offload defers again — step 1.
///
/// The loop closes on itself: every open pays for every day, forever. These tests pin the two properties
/// that break it, and the one that must NOT change.
final class DeferredRescorePlanTests: XCTestCase {

    /// THE fix. The debt says work exists SOMEWHERE in the window; the per-day fingerprint says where.
    /// Re-deriving days whose raw inputs have not moved is work nobody asked for.
    func testSettlementAllowsPerDayReuse() {
        XCTAssertTrue(IntelligenceEngine.deferredRescorePlan().allowDayReuse,
                      "a settlement pass must reuse days whose inputs have not moved")
    }

    /// The half that must stay as it was. A debt is already the answer to "is there work?", recorded
    /// precisely because a pass did not finish; gating on the whole-window fingerprint would ask the
    /// question again and could answer "no" for work that is genuinely outstanding.
    func testSettlementStaysForcedAndUngated() {
        let plan = IntelligenceEngine.deferredRescorePlan()
        XCTAssertTrue(plan.force, "the debt exists because a pass did not finish — it must run")
        XCTAssertFalse(plan.skipIfUnchanged,
                       "gating on the window fingerprint would re-ask a question the debt already answered")
    }

    /// Reuse and force are ORTHOGONAL, and conflating them is what caused this. Force decides whether the
    /// pass runs at all; reuse decides how much of the window it re-derives once it does. A forced pass
    /// that reuses unchanged days is not a weaker pass — it produces identical scores for those days,
    /// because that is what the fingerprint matching on.
    func testForcedAndReusingAreNotInConflict() {
        let plan = IntelligenceEngine.deferredRescorePlan()
        XCTAssertTrue(plan.force && plan.allowDayReuse,
                      "a settlement pass is both: it definitely runs, and it does not redo settled days")
    }

    /// The debt originates from a completed offload — a pure raw-data change — so that is what it is
    /// attributed to. The reason travels into the pass's own bookkeeping, and a wrong one would misreport
    /// why history moved.
    func testSettlementIsAttributedToTheRawChangeThatCausedIt() {
        XCTAssertEqual(IntelligenceEngine.deferredRescorePlan().reason, .rawMutation)
    }

    // MARK: - The policy that produces the debt in the first place

    /// The step-2 half of the loop, stated directly: on a library whose passes exceed the background
    /// budget, every backgrounded trigger defers. That is correct behaviour — a pass killed mid-write is
    /// the outcome worth avoiding — which is exactly why the SETTLEMENT has to be cheap.
    func testALongLibraryDefersEveryBackgroundedTrigger() {
        let decision = RescoreBackgroundPolicy.decide(
            isBackground: true, rescoreAlreadyOwed: false,
            lastCompletedPassSeconds: RescoreBackgroundPolicy.backgroundBudgetSeconds + 1)
        guard case .deferToBackgroundTask = decision else {
            return XCTFail("a pass over the background budget must defer, got \(decision)")
        }
    }

    /// Foreground always runs — the settlement path is a foreground path, so it is never deferred back
    /// into the queue it is draining.
    func testForegroundNeverDefers() {
        let decision = RescoreBackgroundPolicy.decide(
            isBackground: false, rescoreAlreadyOwed: true,
            lastCompletedPassSeconds: RescoreBackgroundPolicy.backgroundBudgetSeconds * 100)
        guard case .run = decision else {
            return XCTFail("foreground must run, got \(decision)")
        }
    }
}

/// Pins the polarity of `allowDayReuse` (#1005 / the fork's v38–v40 fingerprint mechanism).
///
/// Measured on a real 2.8 GB library before this changed: `day-skip: scanned=21 reused=0 of 21`, 2261 s
/// per pass — while 15 of the last 17 days carried a stored `inputRevision` byte-identical to the current
/// one and would every one of them have been reused. The mechanism was not broken; nine of eleven callers
/// simply never asked for it, because not asking was the default.
///
/// Upstream does not have this problem: its in-memory `AnalyzeRecentDayCache` is unconditional. This fork
/// built the better mechanism — persisted, survives relaunch, invalidated by the write side — and then
/// made it opt-in. Flipping the default is what connects the two.
@MainActor
final class DayReuseDefaultTests: XCTestCase {

    /// Reuse is the default; refusing it is the thing a caller must state. The direction matters more than
    /// the value: with the old polarity, forgetting the argument cost a full re-derivation of every day,
    /// and forgetting is what nine call sites did.
    func testReuseIsTheDefault() {
        XCTAssertTrue(IntelligenceEngine.dayReuseDefault,
                      "reuse must be what a caller gets without asking — refusing it is the exception")
    }

    /// The settlement pass takes the default rather than restating it, so the two can never disagree about
    /// what an ordinary pass does.
    func testSettlementFollowsTheDefault() {
        XCTAssertEqual(IntelligenceEngine.deferredRescorePlan().allowDayReuse,
                       IntelligenceEngine.dayReuseDefault)
    }
}

/// Pins the semantic-signature field diff (D1 follow-up).
///
/// D1 measured `miss: semanticSignature=21` on a real device — all 21 days invalidated at once by the
/// one pass-global string that folds twelve values. Naming the group is not yet actionable: a profile
/// field written as a side effect and a deliberate settings change look identical at that level.
@MainActor
final class SemanticSignatureDiffTests: XCTestCase {

    private let base = "weight=4641576901735455130|height=4641135337865740288|age=35|sex=male"
        + "|hrmax=193|stepTicks=4609434218613702656|tz=7200|deepHrv=1|spo2Candidate=1"
        + "|effortMethod=edwards|hrvEpoch=0.0|recoveryEpoch=0.0"

    func testIdenticalSignaturesDifferInNothing() {
        XCTAssertEqual(IntelligenceEngine.semanticSignatureDiff(stored: base, current: base), [])
    }

    /// THE case the device hit: one field moved, and the diff has to say which — with both values, so a
    /// stale write is distinguishable from a real change.
    func testNamesTheSingleFieldThatMoved() {
        let moved = base.replacingOccurrences(of: "hrmax=193", with: "hrmax=195")
        let diff = IntelligenceEngine.semanticSignatureDiff(stored: base, current: moved)
        XCTAssertEqual(diff, ["hrmax: 193 → 195"])
    }

    /// Several at once are all listed, sorted, so two logs of the same shape are diffable.
    func testListsEveryChangedFieldSorted() {
        let moved = base
            .replacingOccurrences(of: "tz=7200", with: "tz=3600")
            .replacingOccurrences(of: "age=35", with: "age=36")
        XCTAssertEqual(IntelligenceEngine.semanticSignatureDiff(stored: base, current: moved),
                       ["age: 35 → 36", "tz: 7200 → 3600"])
    }

    /// A field appearing or vanishing (the format gained or lost a key between builds) is reported as
    /// such rather than silently ignored — that is itself a reason every day would invalidate.
    func testAppearingFieldIsReported() {
        let diff = IntelligenceEngine.semanticSignatureDiff(stored: base, current: base + "|newKey=1")
        XCTAssertEqual(diff, ["newKey: <absent> → 1"])
    }

    /// An unparseable side yields nothing rather than a misleading "everything changed" list.
    func testUnparseableInputYieldsNoDiff() {
        XCTAssertEqual(IntelligenceEngine.semanticSignatureDiff(stored: "", current: base), [])
        XCTAssertEqual(IntelligenceEngine.semanticSignatureDiff(stored: base, current: ""), [])
    }
}
