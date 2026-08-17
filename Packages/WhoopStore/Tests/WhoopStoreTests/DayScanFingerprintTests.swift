import XCTest
import WhoopProtocol
@testable import WhoopStore

/// The skip contract for the analyze scan's per-day fingerprint.
///
/// The whole point of this table is to let a day be SKIPPED, so every test here is really asking the
/// same question from a different side: can it ever say "unchanged" about a day that actually changed?
/// A false "changed" costs one redundant scan; a false "unchanged" leaves a day permanently wrong.
final class DayScanFingerprintTests: XCTestCase {

    private func fp(_ day: String, owner: String = "whoop-1", count: Int = 100, maxTs: Int = 5000,
                    skin: Double? = nil) -> DayScanFingerprint {
        DayScanFingerprint(day: day, ownerId: owner, hrCount: count, hrMaxTs: maxTs, nightlySkinC: skin)
    }

    func testRoundTripsAndKeysByDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDayScanFingerprints(
            [fp("2026-08-01", count: 10, maxTs: 111, skin: 33.5),
             fp("2026-08-02", count: 20, maxTs: 222)], deviceId: "my-whoop-noop")

        let got = try await store.dayScanFingerprints(deviceId: "my-whoop-noop",
                                                      from: "2026-08-01", to: "2026-08-02")
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got["2026-08-01"]?.hrCount, 10)
        XCTAssertEqual(got["2026-08-01"]?.hrMaxTs, 111)
        XCTAssertEqual(got["2026-08-01"]?.nightlySkinC, 33.5)
        XCTAssertNil(got["2026-08-02"]?.nightlySkinC, "a night with no skin samples stores nil, not 0")
    }

    func testWindowIsInclusiveAndScopedToTheComputedNamespace() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDayScanFingerprints(
            [fp("2026-07-31"), fp("2026-08-01"), fp("2026-08-02"), fp("2026-08-03")],
            deviceId: "my-whoop-noop")
        try await store.upsertDayScanFingerprints([fp("2026-08-01")], deviceId: "other-noop")

        let got = try await store.dayScanFingerprints(deviceId: "my-whoop-noop",
                                                      from: "2026-08-01", to: "2026-08-02")
        XCTAssertEqual(Set(got.keys), ["2026-08-01", "2026-08-02"], "inclusive on both bounds")

        let other = try await store.dayScanFingerprints(deviceId: "other-noop",
                                                        from: "2026-08-01", to: "2026-08-01")
        XCTAssertEqual(other.count, 1, "a second computed namespace keeps its own fingerprints")
    }

    func testReScoringADayReplacesItsFingerprint() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDayScanFingerprints([fp("2026-08-01", count: 10, maxTs: 100)],
                                                  deviceId: "my-whoop-noop")
        try await store.upsertDayScanFingerprints([fp("2026-08-01", count: 99, maxTs: 900)],
                                                  deviceId: "my-whoop-noop")
        let got = try await store.dayScanFingerprints(deviceId: "my-whoop-noop",
                                                      from: "2026-08-01", to: "2026-08-01")
        XCTAssertEqual(got.count, 1, "upsert by (deviceId, day) — never a second row for the same day")
        XCTAssertEqual(got["2026-08-01"]?.hrCount, 99)
    }

    // MARK: - inputsMatch: the actual skip decision

    func testUnchangedInputsMatch() {
        XCTAssertTrue(fp("d", count: 10, maxTs: 100).inputsMatch(fp("d", count: 10, maxTs: 100)))
    }

    /// A backfilled OLDER night adds rows without moving maxTs — the case a maxTs-only detector misses.
    func testMoreRowsAtTheSameMaxTsCountsAsChanged() {
        XCTAssertFalse(fp("d", count: 10, maxTs: 100).inputsMatch(fp("d", count: 11, maxTs: 100)))
    }

    /// A fresh append moves maxTs. Counting alone could tie after a delete-plus-insert of equal size.
    func testANewerSampleCountsAsChanged() {
        XCTAssertFalse(fp("d", count: 10, maxTs: 100).inputsMatch(fp("d", count: 10, maxTs: 101)))
    }

    /// I2: exactly one device owns a day. If the resolver picks a different owner, the day is read from
    /// different data entirely — even when that owner's own counts happen to coincide.
    func testADifferentOwnerCountsAsChanged() {
        XCTAssertFalse(fp("d", owner: "whoop-1").inputsMatch(fp("d", owner: "whoop-2")))
    }

    /// `nightlySkinC` is an OUTPUT carried for baseline re-seeding. Comparing it would make a day look
    /// changed because of its own result, which would defeat the skip on every skin-bearing night.
    func testTheCarriedSkinMeanIsNotPartOfTheComparison() {
        XCTAssertTrue(fp("d", skin: 33.0).inputsMatch(fp("d", skin: 34.0)))
    }

    /// A day we have no record for must never read as "unchanged" — absence means scan.
    func testAnAbsentDayIsNotSkippable() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDayScanFingerprints([fp("2026-08-01")], deviceId: "my-whoop-noop")
        let got = try await store.dayScanFingerprints(deviceId: "my-whoop-noop",
                                                      from: "2026-08-01", to: "2026-08-05")
        XCTAssertNil(got["2026-08-04"], "no record → the caller has nothing to match → it scans")
    }

    /// The escape hatch for an ALGORITHM change: the raw bytes are untouched, so every input fingerprint
    /// still matches and the new scoring would never reach the old days unless the records are dropped.
    func testClearForcesAFullRescan() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDayScanFingerprints([fp("2026-08-01"), fp("2026-08-02")],
                                                  deviceId: "my-whoop-noop")
        try await store.upsertDayScanFingerprints([fp("2026-08-01")], deviceId: "keep-noop")

        let deleted = try await store.clearDayScanFingerprints(deviceId: "my-whoop-noop")
        XCTAssertEqual(deleted, 2)
        let gone = try await store.dayScanFingerprints(deviceId: "my-whoop-noop",
                                                       from: "0000-01-01", to: "9999-12-31")
        XCTAssertTrue(gone.isEmpty)
        let kept = try await store.dayScanFingerprints(deviceId: "keep-noop",
                                                       from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(kept.count, 1, "clearing one namespace leaves another's records alone")
    }

    /// The fingerprint has to be derivable from what the store already offers, cheaply — `hrFingerprint`
    /// is that query, and until now it had no production caller. This pins the two together so the
    /// per-day check keeps meaning "this day's raw HR", not something re-derived by hand.
    func testHrFingerprintSuppliesTheInputNumbers() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "whoop-1", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60),
                                                HRSample(ts: 200, bpm: 61)]), deviceId: "whoop-1")
        let probe = try await store.hrFingerprint(deviceId: "whoop-1", from: 0, to: 1000)
        let recorded = DayScanFingerprint(day: "2026-08-01", ownerId: "whoop-1",
                                          hrCount: probe.count, hrMaxTs: probe.maxTs, nightlySkinC: nil)
        XCTAssertEqual(recorded.hrCount, 2)
        XCTAssertEqual(recorded.hrMaxTs, 200)

        // One more sample in the window → the probe moves → the day no longer matches.
        _ = try await store.insert(Streams(hr: [HRSample(ts: 300, bpm: 62)]), deviceId: "whoop-1")
        let after = try await store.hrFingerprint(deviceId: "whoop-1", from: 0, to: 1000)
        XCTAssertFalse(recorded.inputsMatch(DayScanFingerprint(day: "2026-08-01", ownerId: "whoop-1",
                                                               hrCount: after.count, hrMaxTs: after.maxTs,
                                                               nightlySkinC: nil)))
    }
}
