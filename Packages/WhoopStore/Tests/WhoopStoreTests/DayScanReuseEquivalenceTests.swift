import XCTest
import WhoopProtocol
@testable import WhoopStore

/// The promise the per-day skip has to keep: **reusing a day must be indistinguishable from
/// re-deriving it.**
///
/// The skip exists because re-deriving a day costs a ~54 h read plus sleep staging, and almost every
/// day in the window is unchanged. That is only worth anything if a skipped day is not quietly
/// different from a scanned one — a score that depends on WHEN it happened to be computed is worse
/// than a slow one.
///
/// The scoring engine itself lives in the app target, so these tests pin the STORE-side contract the
/// engine's decision rests on: the fingerprint answers "same inputs?" and nothing else, it answers it
/// the same way twice, and every way a day's inputs can move is a way it answers "no".
final class DayScanReuseEquivalenceTests: XCTestCase {

    private let dev = "my-whoop-noop"
    private let owner = "whoop-535B"

    private func traits(consistency: Double? = 0.8, need: Double = 8.0,
                        midsleep: Int? = 4 * 3600) -> DayScanFingerprint.TraitSignature {
        DayScanFingerprint.TraitSignature(consistency: consistency, needHours: need, midsleepSec: midsleep)
    }

    /// Seed a day's raw HR and return the fingerprint a scan of `[from, to]` would record for it.
    private func recordDay(_ store: WhoopStore, day: String, samples: [HRSample],
                           from: Int, to: Int,
                           traits t: DayScanFingerprint.TraitSignature) async throws -> DayScanFingerprint {
        if !samples.isEmpty { _ = try await store.insert(Streams(hr: samples), deviceId: owner) }
        let probe = try await store.hrFingerprint(deviceId: owner, from: from, to: to)
        let fp = DayScanFingerprint(day: day, ownerId: owner, hrCount: probe.count, hrMaxTs: probe.maxTs,
                                    nightlySkinC: 33.2, traits: t)
        try await store.upsertDayScanFingerprints([fp], deviceId: dev)
        return fp
    }

    /// The steady state this whole change is for: nothing synced, so the day must be reusable.
    func testAnUntouchedDayIsReusable() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: owner, mac: nil, name: nil)
        let recorded = try await recordDay(store, day: "2026-08-01",
                                           samples: (0..<50).map { HRSample(ts: 1000 + $0, bpm: 60) },
                                           from: 0, to: 10_000, traits: traits())

        // A later pass re-probes the same window with the same traits.
        let probe = try await store.hrFingerprint(deviceId: owner, from: 0, to: 10_000)
        let now = DayScanFingerprint(day: "2026-08-01", ownerId: owner, hrCount: probe.count,
                                     hrMaxTs: probe.maxTs, nightlySkinC: nil, traits: traits())
        let stored = try await store.dayScanFingerprints(deviceId: dev, from: "2026-08-01", to: "2026-08-01")
        XCTAssertEqual(stored["2026-08-01"], recorded)
        XCTAssertTrue(stored["2026-08-01"]?.inputsMatch(now) ?? false,
                      "nothing changed — this day must not be re-derived")
    }

    /// Every way a day's inputs can actually move must defeat the skip. Each case is a way a wearer
    /// could end up with a permanently stale score if the fingerprint were too forgiving.
    func testEveryRealChangeDefeatsTheSkip() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: owner, mac: nil, name: nil)
        try await store.upsertDevice(id: "whoop-other", mac: nil, name: nil)
        let recorded = try await recordDay(store, day: "2026-08-01",
                                           samples: (0..<50).map { HRSample(ts: 1000 + $0, bpm: 60) },
                                           from: 0, to: 10_000, traits: traits())

        func probeNow(owner o: String = "whoop-535B",
                      traits t: DayScanFingerprint.TraitSignature? = nil) async throws -> DayScanFingerprint {
            let p = try await store.hrFingerprint(deviceId: o, from: 0, to: 10_000)
            return DayScanFingerprint(day: "2026-08-01", ownerId: o, hrCount: p.count, hrMaxTs: p.maxTs,
                                      nightlySkinC: nil, traits: t ?? traits())
        }

        // 1. A fresh append (a normal sync bringing the night's tail).
        _ = try await store.insert(Streams(hr: [HRSample(ts: 2000, bpm: 61)]), deviceId: owner)
        let afterAppend = try await probeNow()
        XCTAssertFalse(recorded.inputsMatch(afterAppend), "new samples → re-derive")

        // 2. A BACKFILLED older sample: more rows, and `maxTs` does NOT move. This is the case a
        //    maxTs-only detector misses entirely.
        _ = try await store.insert(Streams(hr: [HRSample(ts: 500, bpm: 59)]), deviceId: owner)
        let afterBackfill = try await probeNow()
        XCTAssertFalse(afterAppend.inputsMatch(afterBackfill),
                       "a backfilled older sample raises the count without moving maxTs")
        XCTAssertEqual(afterAppend.hrMaxTs, afterBackfill.hrMaxTs,
                       "…and it is genuinely the COUNT that caught it, not maxTs")

        // 3. The day resolving to a DIFFERENT owner (I2: exactly one device owns a day).
        let sameOwner = try await probeNow()
        let otherOwner = try await probeNow(owner: "whoop-other")
        XCTAssertFalse(sameOwner.inputsMatch(otherOwner), "a different owner means different data entirely")

        // 4. A learned trait moving — invisible in the raw stream, but it changes the stored Rest score.
        let shiftedTrait = try await probeNow(traits: traits(consistency: 0.5))
        XCTAssertFalse(sameOwner.inputsMatch(shiftedTrait),
                       "a shifted trait must re-derive, or the day freezes on the old value")
    }

    /// Deleting a device's data takes its fingerprints with it. Otherwise a re-add would meet records
    /// claiming days are unchanged when their raw rows are gone — the worst failure this table has,
    /// because the day would never be re-derived and would keep scores computed from deleted data.
    func testDeletingDeviceDataRemovesItsFingerprints() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: owner, mac: nil, name: nil)
        _ = try await recordDay(store, day: "2026-08-01",
                                samples: [HRSample(ts: 1000, bpm: 60)],
                                from: 0, to: 10_000, traits: traits())

        try await store.deleteAllData(deviceId: dev)
        let after = try await store.dayScanFingerprints(deviceId: dev, from: "0000-01-01", to: "9999-12-31")
        XCTAssertTrue(after.isEmpty, "a fingerprint must never outlive the data it describes")
    }

    /// Re-probing without changing anything must give the same answer. A fingerprint that drifted on
    /// its own would either re-derive forever (no benefit) or, worse, match by accident.
    func testTheProbeIsStable() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: owner, mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: (0..<200).map { HRSample(ts: 1000 + $0, bpm: 60 + $0 % 5) }),
                                   deviceId: owner)
        let a = try await store.hrFingerprint(deviceId: owner, from: 0, to: 10_000)
        let b = try await store.hrFingerprint(deviceId: owner, from: 0, to: 10_000)
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a.maxTs, b.maxTs)
    }

    /// Re-inserting the SAME samples is idempotent at the store (ON CONFLICT DO NOTHING), so a
    /// duplicate offload must not look like a change — otherwise a flapping link would re-derive the
    /// window on every reconnect, which is the churn the post-offload gate exists to stop.
    func testADuplicateOffloadIsNotAChange() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: owner, mac: nil, name: nil)
        let batch = (0..<50).map { HRSample(ts: 1000 + $0, bpm: 60) }
        let recorded = try await recordDay(store, day: "2026-08-01", samples: batch,
                                           from: 0, to: 10_000, traits: traits())

        _ = try await store.insert(Streams(hr: batch), deviceId: owner)   // the same rows again
        let p = try await store.hrFingerprint(deviceId: owner, from: 0, to: 10_000)
        let now = DayScanFingerprint(day: "2026-08-01", ownerId: owner, hrCount: p.count, hrMaxTs: p.maxTs,
                                     nightlySkinC: nil, traits: traits())
        XCTAssertTrue(recorded.inputsMatch(now), "re-sending identical rows banks nothing new")
    }

    /// Days are independent: touching one must not invalidate its neighbours, or a nightly sync would
    /// still re-derive the whole window.
    func testTouchingOneDayLeavesTheOthersReusable() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: owner, mac: nil, name: nil)
        // Two disjoint day windows.
        let d1 = try await recordDay(store, day: "2026-08-01",
                                     samples: (0..<20).map { HRSample(ts: 1_000 + $0, bpm: 60) },
                                     from: 0, to: 5_000, traits: traits())
        let d2 = try await recordDay(store, day: "2026-08-02",
                                     samples: (0..<20).map { HRSample(ts: 10_000 + $0, bpm: 62) },
                                     from: 9_000, to: 15_000, traits: traits())

        // A sync lands data only in day 2's window.
        _ = try await store.insert(Streams(hr: [HRSample(ts: 11_000, bpm: 63)]), deviceId: owner)

        let p1 = try await store.hrFingerprint(deviceId: owner, from: 0, to: 5_000)
        XCTAssertTrue(d1.inputsMatch(DayScanFingerprint(day: "2026-08-01", ownerId: owner,
                                                         hrCount: p1.count, hrMaxTs: p1.maxTs,
                                                         nightlySkinC: nil, traits: traits())),
                      "day 1 was not touched and must stay reusable")
        let p2 = try await store.hrFingerprint(deviceId: owner, from: 9_000, to: 15_000)
        XCTAssertFalse(d2.inputsMatch(DayScanFingerprint(day: "2026-08-02", ownerId: owner,
                                                          hrCount: p2.count, hrMaxTs: p2.maxTs,
                                                          nightlySkinC: nil, traits: traits())),
                       "day 2 received the sync and must be re-derived")
    }
}
