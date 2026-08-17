import XCTest
import WhoopProtocol
@testable import WhoopStore

/// The skip contract for the analyze scan's per-day fingerprint.
///
/// The whole point of this table is to let a day be SKIPPED, so every test here is really asking the
/// same question from a different side: can it ever say "unchanged" about a day that actually changed?
/// A false "changed" costs one redundant scan; a false "unchanged" leaves a day permanently wrong.
final class DayScanFingerprintTests: XCTestCase {

    /// A stable trait signature, so the raw-input tests below vary only what they mean to vary.
    private func traits(consistency: Double? = 0.80, need: Double = 8.0,
                        midsleep: Int? = 4 * 3600) -> DayScanFingerprint.TraitSignature {
        DayScanFingerprint.TraitSignature(consistency: consistency, needHours: need, midsleepSec: midsleep)
    }

    private func fp(_ day: String, owner: String = "whoop-1", count: Int = 100, maxTs: Int = 5000,
                    skin: Double? = nil,
                    traits t: DayScanFingerprint.TraitSignature? = nil,
                    inputRevision: Int = 7, deviceRevision: Int = 1,
                    scoringVersion: Int = 1, semanticSignature: String = "profile-v1") -> DayScanFingerprint {
        DayScanFingerprint(day: day, ownerId: owner, hrCount: count, hrMaxTs: maxTs, nightlySkinC: skin,
                           traits: t ?? traits(), inputRevision: inputRevision,
                           deviceRevision: deviceRevision, scoringVersion: scoringVersion,
                           semanticSignature: semanticSignature)
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
        XCTAssertEqual(got["2026-08-01"]?.inputRevision, 7)
        XCTAssertEqual(got["2026-08-01"]?.scoringVersion, 1)
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

    /// Any scoring-stream mutation moves the window revision, including a backfilled older sample.
    func testInputRevisionChangeCountsAsChanged() {
        XCTAssertFalse(fp("d", inputRevision: 7).inputsMatch(fp("d", inputRevision: 8)))
    }

    func testDeviceRevisionAndScoringVersionCountAsChanged() {
        XCTAssertFalse(fp("d", deviceRevision: 1).inputsMatch(fp("d", deviceRevision: 2)))
        XCTAssertFalse(fp("d", scoringVersion: 1).inputsMatch(fp("d", scoringVersion: 2)))
    }

    func testSemanticSignatureCountsAsChanged() {
        XCTAssertFalse(fp("d", semanticSignature: "profile-v1")
            .inputsMatch(fp("d", semanticSignature: "profile-v2")))
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

    // MARK: - Learned traits (v39)
    //
    // These move a day's stored Rest score without moving one byte of its raw input, so the raw probe
    // cannot see them. If they were left out, a day reused across a trait shift would sit frozen on the
    // old values while its neighbours moved — and a forced full rescore would no longer reproduce it.

    func testAShiftedSleepConsistencyCountsAsChanged() {
        XCTAssertFalse(fp("d", traits: traits(consistency: 0.80))
            .inputsMatch(fp("d", traits: traits(consistency: 0.90))))
    }

    func testAShiftedSleepNeedCountsAsChanged() {
        XCTAssertFalse(fp("d", traits: traits(need: 8.0)).inputsMatch(fp("d", traits: traits(need: 8.4))))
    }

    func testAShiftedHabitualMidsleepCountsAsChanged() {
        XCTAssertFalse(fp("d", traits: traits(midsleep: 4 * 3600))
            .inputsMatch(fp("d", traits: traits(midsleep: 5 * 3600))))
    }

    /// The quantisation is the whole point: the 28-night regularity window shifts a little every night,
    /// and invalidating the window daily would cost exactly what this table exists to save. Sub-resolution
    /// jitter must therefore still match.
    func testSubResolutionJitterStillMatches() {
        XCTAssertTrue(fp("d", traits: traits(consistency: 0.8000))
            .inputsMatch(fp("d", traits: traits(consistency: 0.8004))),
                      "consistency is compared at 1/100")
        XCTAssertTrue(fp("d", traits: traits(need: 8.00)).inputsMatch(fp("d", traits: traits(need: 8.04))),
                      "sleep need is compared at 0.1 h")
        XCTAssertTrue(fp("d", traits: traits(midsleep: 4 * 3600))
            .inputsMatch(fp("d", traits: traits(midsleep: 4 * 3600 + 20))),
                      "midsleep is compared to the minute")
    }

    /// A v38 row has no recorded traits. We cannot show it was scored against today's traits, and
    /// "cannot show" has to read the same as "was not" — otherwise the upgrade would silently keep days
    /// that were scored against unknown values.
    func testARowWithoutRecordedTraitsIsNeverReused() {
        let legacy = DayScanFingerprint(day: "d", ownerId: "whoop-1", hrCount: 100, hrMaxTs: 5000,
                                        nightlySkinC: nil, traits: nil)
        XCTAssertFalse(legacy.inputsMatch(fp("d")), "stored row predates v39 → scan it")
        XCTAssertFalse(fp("d").inputsMatch(legacy), "and the probe having no traits is a mismatch too")
    }

    func testTraitsRoundTripThroughTheStore() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDayScanFingerprints(
            [fp("2026-08-01", traits: traits(consistency: 0.73, need: 7.5, midsleep: 3 * 3600 + 1800))],
            deviceId: "my-whoop-noop")
        let got = try await store.dayScanFingerprints(deviceId: "my-whoop-noop",
                                                      from: "2026-08-01", to: "2026-08-01")
        XCTAssertEqual(got["2026-08-01"]?.traits?.consistencyHundredths, 73)
        XCTAssertEqual(got["2026-08-01"]?.traits?.needHoursTenths, 75)
        XCTAssertEqual(got["2026-08-01"]?.traits?.midsleepMinutes, 210)
        XCTAssertTrue(got["2026-08-01"]?.inputsMatch(
            fp("2026-08-01", traits: traits(consistency: 0.73, need: 7.5, midsleep: 3 * 3600 + 1800))) ?? false,
                      "a stored row still matches the traits it was written with")
    }

    /// A cold-start wearer has no regularity and no learned midsleep yet. Absent-on-both must MATCH, or
    /// no day would ever be reusable until enough history accrues.
    func testAbsentOptionalTraitsMatchWhenBothAreAbsent() {
        let a = fp("d", traits: traits(consistency: nil, midsleep: nil))
        let b = fp("d", traits: traits(consistency: nil, midsleep: nil))
        XCTAssertTrue(a.inputsMatch(b))
        XCTAssertFalse(a.inputsMatch(fp("d", traits: traits(consistency: 0.5, midsleep: nil))),
                       "gaining a consistency reading IS a change")
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

    /// The revision probe covers non-HR streams and remains bounded to the UTC buckets intersecting the
    /// analysis window.
    func testAnalysisRevisionSuppliesTheInputVersion() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "whoop-1", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60),
                                                HRSample(ts: 200, bpm: 61)]), deviceId: "whoop-1")
        let probe = try await store.analysisInputRevision(deviceId: "whoop-1", from: 0, to: 1000)
        let recorded = DayScanFingerprint(day: "2026-08-01", ownerId: "whoop-1",
                                          hrCount: 0, hrMaxTs: 0, nightlySkinC: nil,
                                          traits: traits(), inputRevision: probe.inputRevision,
                                          deviceRevision: probe.deviceRevision, scoringVersion: 1,
                                          semanticSignature: "profile-v1")
        XCTAssertGreaterThan(probe.inputRevision, 0)

        // A non-HR scoring stream moves the same contract.
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 300, rrMs: 800)]), deviceId: "whoop-1")
        let after = try await store.analysisInputRevision(deviceId: "whoop-1", from: 0, to: 1000)
        XCTAssertFalse(recorded.inputsMatch(DayScanFingerprint(day: "2026-08-01", ownerId: "whoop-1",
                                                               hrCount: 0, hrMaxTs: 0, nightlySkinC: nil,
                                                               traits: traits(), inputRevision: after.inputRevision,
                                                               deviceRevision: after.deviceRevision, scoringVersion: 1,
                                                               semanticSignature: "profile-v1")))
    }
}
