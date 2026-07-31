import XCTest
@testable import Strand

/// Default order, encode/decode round-trip, reorder, and the never-hide "insert missing section at its
/// default position" invariant (#today-layout), pinning the persisted "today.sectionOrder" wire format.
///
/// Formerly the twin of the Android `TodayLayoutPrefsTest`. That is no longer a contract: the parity
/// obligation was retired on 2026-07-23 (iOS/macOS-only — see CLAUDE.md), and the enums have since
/// diverged, `coach` and `dataSources` existing only here. The wire format still matters for THIS
/// platform's saved layouts, so the raw keys stay pinned below — just not against Kotlin.
final class TodayLayoutPrefsTests: XCTestCase {

    func testEmptyOrUnsetYieldsDefaultOrder() {
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(""), TodaySection.defaultOrder)
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder("   "), TodaySection.defaultOrder)
    }

    /// `coach` sits deliberately mid-list rather than at the front: it is FIRST in `defaultOrder`, so a
    /// decoder that re-inserted it at its default position instead of honouring the saved one would still
    /// look right in every other test here.
    func testEncodeDecodeRoundTripsAReorderedList() {
        let reordered: [TodaySection] = [
            .heartRate, .hero, .yourCards, .coach, .liveSession, .synthesis, .keyMetrics, .workouts,
            .recoveryVitals, .journal, .dataSources,
        ]
        let encoded = TodayLayoutPrefs.encode(reordered)
        XCTAssertEqual(encoded, "heartRate,hero,yourCards,coach,liveSession,synthesis,keyMetrics,workouts,recoveryVitals,journal,dataSources")
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(encoded), reordered)
    }

    /// The v1 upgrade path: an order saved by the FIRST cut (6 sections — no hero/liveSession, which were
    /// pinned then) must surface the newer sections at the TOP (their default position), not teleport
    /// them to the bottom of the user's saved order. `coach` is the newest such section and leads the
    /// default order, so it lands ahead of hero/liveSession.
    func testSavedOrderFromFirstCutInsertsHeroAndSessionAtTheirDefaultPosition() {
        let firstCut = "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(firstCut),
            // journal then dataSources follow everything saved → appended in default order.
            [.coach, .hero, .liveSession, .synthesis, .keyMetrics, .workouts, .heartRate, .recoveryVitals, .yourCards, .journal, .dataSources]
        )
    }

    func testInsertsAnyMissingSectionAtItsDefaultPositionRelativeToSaved() {
        let partial = "heartRate,synthesis,keyMetrics,recoveryVitals"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(partial),
            [.coach, .hero, .liveSession, .workouts, .heartRate, .synthesis, .keyMetrics, .recoveryVitals, .yourCards, .journal, .dataSources]
        )
    }

    func testDropsUnknownTokensAndCollapsesDuplicates() {
        let messy = "yourCards,BOGUS,yourCards,heartRate, ,heartRate"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(messy),
            [.coach, .hero, .liveSession, .synthesis, .keyMetrics, .workouts, .recoveryVitals, .yourCards, .heartRate, .journal, .dataSources]
        )
    }

    func testAllJunkYieldsDefaultOrder() {
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder("nope,,zzz"), TodaySection.defaultOrder)
    }

    /// defaultOrder must cover EVERY case: the never-hide merge iterates it, so a case missing from the
    /// default order could otherwise be dropped from render (Android) or mis-sorted (iOS).
    func testDefaultOrderCoversEveryCase() {
        XCTAssertEqual(Set(TodaySection.defaultOrder), Set(TodaySection.allCases))
        XCTAssertEqual(TodaySection.defaultOrder.count, TodaySection.allCases.count)
    }

    func testSectionRawKeysAreStableAndUnique() {
        let raws = TodaySection.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "raw keys must be unique (they're the persisted identity)")
        // Pin the exact wire strings: they are the persisted identity, so renaming one silently resets
        // that section's saved position for every existing user.
        XCTAssertEqual(
            raws,
            ["coach", "hero", "liveSession", "synthesis", "keyMetrics", "workouts", "heartRate", "recoveryVitals", "yourCards", "journal", "dataSources"]
        )
    }
}
