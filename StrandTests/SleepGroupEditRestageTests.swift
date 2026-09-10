import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// A hand-corrected night that GROWS must have its recovered hours re-derived from the raw streams.
///
/// The regression this pins: `SleepGroupEdit`'s planner can only RESHAPE stages that already exist, so
/// `SleepWindowReclip` fills time the old window never covered with one fabricated trailing "wake" block.
/// That block is not cosmetic — the stored `stagesJSON` IS the night's truth for the daily rollup and the
/// Sleep tab, so extending a night the detector truncated left total sleep exactly where it was while
/// in-bed grew, which DROPPED the Rest score instead of correcting it. The single-session edit path always
/// re-staged from raw first; the bridged-night rewrite dropped that step.
///
/// The assertions deliberately test WHICH PATH RAN rather than which stages came out: a re-stage returns a
/// 30 s-epoch segmentation of the whole window, while the re-clip returns the untouched original segments
/// plus exactly one `wake` block spanning the extension. That distinction is the fix, and it holds
/// whatever the stager concludes about this synthetic night.
final class SleepGroupEditRestageTests: XCTestCase {

    private let deviceId = "my-whoop"
    /// The night as the detector left it: one hour, staged `light` end to end.
    private let detectedStart = 1_700_000_000
    private let detectedEnd = 1_700_003_600
    /// Three further hours the wearer actually slept, which the detector cut off.
    private let correctedEnd = 1_700_014_400

    private func stagedNight() -> String? {
        AnalyticsEngine.encodeStages(
            [StageSegment(start: detectedStart, end: detectedEnd, stage: "light")])
    }

    /// Seed a densely worn window so `restageFromRaw` clears its ~1 sample / 2 min density gate. One
    /// gravity/HR sample every 30 s across the corrected window is ~4x the floor; the R-R keeps the
    /// cardiorespiratory stager fed.
    private func seedWornRaw(_ store: WhoopStore, from: Int, to: Int) async throws {
        var streams = Streams.empty
        for ts in stride(from: from, to: to, by: 30) {
            // A near-still wrist with a slow drift, so the still-run spine has something real to read.
            let drift = Double(ts % 600) / 60_000.0
            streams.gravity.append(GravitySample(ts: ts, x: drift, y: 0.02, z: 0.98))
            streams.hr.append(HRSample(ts: ts, bpm: 52))
            streams.rr.append(RRInterval(ts: ts, rrMs: 1_150))
        }
        _ = try await store.insert(streams, deviceId: deviceId)
    }

    private func segments(_ json: String?) throws -> [(start: Int, end: Int, stage: String)] {
        let data = try XCTUnwrap(json?.data(using: .utf8))
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return raw.compactMap {
            guard let s = ($0["start"] as? NSNumber)?.intValue,
                  let e = ($0["end"] as? NSNumber)?.intValue,
                  let stage = $0["stage"] as? String else { return nil }
            return (start: s, end: e, stage: stage)
        }.sorted { $0.start < $1.start }
    }

    @MainActor
    private func makeRepo(_ store: WhoopStore) -> Repository {
        let repo = Repository(deviceId: deviceId)
        repo.setStoreForTesting(store)
        return repo
    }

    // MARK: - The fix

    /// THE regression. Extending the wake time must not bank hours of fabricated "awake".
    @MainActor
    func testExtendingAWindowRestagesTheRecoveredHoursFromRaw() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
        try await seedWornRaw(store, from: detectedStart, to: correctedEnd)
        let night = CachedSleepSession(startTs: detectedStart, endTs: detectedEnd, efficiency: 0.9,
                                       restingHr: 52, avgHrv: 60, stagesJSON: stagedNight())
        _ = try await store.upsertSleepSessions([night], deviceId: deviceId + "-noop")

        let repo = makeRepo(store)
        let outcome = await repo.editSleepGroupTimes([night], newStartTs: detectedStart,
                                                     newEndTs: correctedEnd)
        guard case .success = outcome else { return XCTFail("the edit must persist, got \(outcome)") }

        let rows = try await store.sleepSessions(deviceId: deviceId + "-noop",
                                                 from: 0, to: correctedEnd + 1, limit: 10)
        let stored = try XCTUnwrap(rows.first)
        XCTAssertEqual(stored.endTs, correctedEnd, "the corrected wake time is stored")
        XCTAssertTrue(stored.userEdited)

        let segs = try segments(stored.stagesJSON)
        // The re-clip's signature is the ORIGINAL segment plus exactly one wake block over the extension.
        let fabricatedTail = segs.contains {
            $0.stage == "wake" && $0.start == detectedEnd && $0.end == correctedEnd
        }
        XCTAssertFalse(fabricatedTail,
                       "the recovered hours must be staged from raw, not filled with one wake block")
        XCTAssertGreaterThan(segs.count, 1, "a re-stage returns an epoch segmentation, not one block")
        XCTAssertEqual(segs.last?.end, correctedEnd, "the staging covers the corrected window")
    }

    // MARK: - What must NOT change

    /// A window that only NARROWS has no uncovered time, so it keeps the planner's cheap re-clip. This is
    /// the path every shortening edit takes, and it must stay byte-identical to the pre-fix behaviour —
    /// including on a night with dense raw sitting right there, which is what makes it a real control.
    @MainActor
    func testNarrowingAWindowKeepsTheCheapReclip() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
        try await seedWornRaw(store, from: detectedStart, to: correctedEnd)
        let night = CachedSleepSession(startTs: detectedStart, endTs: detectedEnd, efficiency: 0.9,
                                       restingHr: 52, avgHrv: 60, stagesJSON: stagedNight())
        _ = try await store.upsertSleepSessions([night], deviceId: deviceId + "-noop")

        let shorterEnd = detectedEnd - 600
        let repo = makeRepo(store)
        let outcome = await repo.editSleepGroupTimes([night], newStartTs: detectedStart,
                                                     newEndTs: shorterEnd)
        guard case .success = outcome else { return XCTFail("the edit must persist, got \(outcome)") }

        let rows = try await store.sleepSessions(deviceId: deviceId + "-noop",
                                                 from: 0, to: correctedEnd + 1, limit: 10)
        let stored = try XCTUnwrap(rows.first)
        let expected = SleepWindowReclip.reclip(stagesJSON: stagedNight(),
                                                sessionStart: detectedStart, oldEnd: detectedEnd,
                                                newStart: detectedStart, newEnd: shorterEnd)
        let actualSegments = try segments(stored.stagesJSON)
        let expectedSegments = try segments(expected)
        XCTAssertEqual(actualSegments.map(\.start), expectedSegments.map(\.start))
        XCTAssertEqual(actualSegments.map(\.end), expectedSegments.map(\.end))
        XCTAssertEqual(actualSegments.map(\.stage), expectedSegments.map(\.stage),
                       "a narrowing edit must still take the planner's re-clip semantics")
    }

    /// A night with NO raw (a genuine WHOOP-export import) still extends — it falls back to the re-clip's
    /// trailing wake block rather than refusing the edit. That is the only honest representation when
    /// there is no sensor timeline from which stages could be reconstructed.
    @MainActor
    func testExtendingAnImportedNightWithNoRawFallsBackToTheReclip() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
        let night = CachedSleepSession(startTs: detectedStart, endTs: detectedEnd, efficiency: 0.9,
                                       restingHr: 52, avgHrv: 60, stagesJSON: stagedNight())
        _ = try await store.upsertSleepSessions([night], deviceId: deviceId)   // imported namespace

        let repo = makeRepo(store)
        let outcome = await repo.editSleepGroupTimes([night], newStartTs: detectedStart,
                                                     newEndTs: correctedEnd)
        guard case .success = outcome else { return XCTFail("the edit must persist, got \(outcome)") }

        let rows = try await store.sleepSessions(deviceId: deviceId, from: 0,
                                                 to: correctedEnd + 1, limit: 10)
        let stored = try XCTUnwrap(rows.first)
        XCTAssertEqual(stored.endTs, correctedEnd)
        let segs = try segments(stored.stagesJSON)
        XCTAssertTrue(segs.contains { $0.stage == "wake" && $0.end == correctedEnd },
                      "with no raw to stage, the re-clip fallback is what remains")
    }
}
