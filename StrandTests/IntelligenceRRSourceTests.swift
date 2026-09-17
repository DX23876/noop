import XCTest
import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

@MainActor
final class IntelligenceRRSourceTests: XCTestCase {
    private let canonical = "my-whoop"
    private let active = "new-five"

    private func withPreferences(_ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = [
            "profile.dateOfBirth", "profile.age", "profile.sex", "profile.weightKg",
            "profile.heightCm", "profile.waistCm", "profile.hrMaxOverride", "profile.stepTicksPerStep",
            "profile.stepsCalibrationCoefficient", "profile.stepsCalibrationSampleDays",
            "profile.stepsCalibrationConfidence", "profile.stepsCalibrationManual",
            "profile.stepsManualCoefficient", "profile.stepsHasBankedMotion",
            "noop.analyzeWatermark", "analyzeRecent.stepsMotionCache.v1",
            "noop.hrvBaselineEpoch", "noop.recoveryBaselineEpoch", UnitPrefs.hrvWindowKey,
            RescoreBackgroundScheduler.owedKey, RescoreBackgroundScheduler.owedTokenKey,
            RescoreBackgroundScheduler.lastPassSecondsKey, DayCycleMode.storageKey,
            PuffinExperiment.experimentalSleepV2Key, PuffinExperiment.motionAwareWakeKey,
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(DayCycleMode.midnight.rawValue, forKey: DayCycleMode.storageKey)
        defaults.set(true, forKey: PuffinExperiment.experimentalSleepV2Key)
        defaults.set(false, forKey: PuffinExperiment.motionAwareWakeKey)
        try await body()
    }

    private func register(_ registry: DeviceRegistryStore, canonicalModel: String) throws {
        try registry.add(PairedDevice(id: canonical, brand: "WHOOP", model: canonicalModel,
            sourceKind: .liveBLE, capabilities: [.hr, .hrv], status: .paired, addedAt: 1, lastSeenAt: 1))
        try registry.add(PairedDevice(id: active, brand: "WHOOP", model: "5.0",
            sourceKind: .liveBLE, capabilities: [.hr, .hrv], status: .active, addedAt: 2, lastSeenAt: 2))
    }

    private func seedBaseline(_ store: WhoopStore, before day: String) async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = try XCTUnwrap(formatter.date(from: day))
        let history = (1...8).map { offset in
            DailyMetric(day: formatter.string(from: date.addingTimeInterval(-Double(offset) * 86_400)),
                totalSleepMin: 480, efficiency: 0.9, deepMin: 90, remMin: 90, lightMin: 300,
                disturbances: 0, restingHr: 60, avgHrv: 32 + Double(offset % 3), recovery: 60,
                strain: nil, exerciseCount: nil)
        }
        _ = try await store.upsertDailyMetrics(history, deviceId: canonical)
    }

    /// The #2117 regression this fork refuses to ship: after a WHOOP 5 re-pair, history banked before R-R
    /// rows carried a transport label must keep scoring. Upstream's strict policy read such a window back
    /// EMPTY, which blanked HRV and Charge for nights that had been scored for months.
    func testUnlabelledWhoop5AliasBeatsKeepScoringAndLabelledReOffloadIsIdentical() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            try register(registry, canonicalModel: "WHOOP")
            let input = night()
            try await seedBaseline(store, before: input.day)
            _ = try await store.insert(Streams(hr: input.hr, rr: input.rr), deviceId: canonical)
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            _ = repo.adoptActiveDeviceId(active)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)

            await engine.analyzeRecent(maxDays: 2, force: true)
            let before = try await store.dailyMetrics(deviceId: canonical + "-noop", from: input.day, to: input.day)
            let legacy = try XCTUnwrap(before.first)
            XCTAssertGreaterThan(legacy.totalSleepMin ?? 0, 0, "the fixture must actually score a night")
            let legacyHrv = try XCTUnwrap(legacy.avgHrv, "unlabelled WHOOP 5 history must not be withheld")
            XCTAssertNotNil(legacy.recovery, "Charge follows the HRV it needs")

            // Re-offloading the same beats as labelled v18 history changes provenance only. The values are
            // the same milliseconds, so the score must not move.
            let tagged = input.rr.map { RRInterval(ts: $0.ts, rrMs: $0.rrMs, srcChannel: .whoop5Historical) }
            let inserted = try await store.insert(Streams(rr: tagged), deviceId: canonical)
            XCTAssertEqual(inserted.rr, 0, "only provenance changes; the existing interval keys are identical")
            await engine.analyzeRecent(maxDays: 2, force: true)
            let after = try await store.dailyMetrics(deviceId: canonical + "-noop", from: input.day, to: input.day)
            XCTAssertEqual(try XCTUnwrap(after.first?.avgHrv), legacyHrv, accuracy: 0.0001)
        }
    }

    // A completed night relative to the test's local day, using the established HR-only sleep fixture.
    private func night() -> (day: String, hr: [HRSample], rr: [RRInterval]) {
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) - 86_400
        let day = Repository.localDayKey(Date(timeIntervalSince1970: Double(start)))
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for i in 0..<(24 * 3_600) {
            let asleep = i >= 16 * 3_600
            let phase = asleep ? i - 16 * 3_600 : i
            let bpm = asleep ? 64 + Int(sin(Double(phase) / 900) * 5)
                             : 74 + Int(sin(Double(phase) / 500) * 11)
            let ts = start - 16 * 3_600 + i
            hr.append(HRSample(ts: ts, bpm: bpm))
            rr.append(RRInterval(ts: ts, rrMs: 900 + (i.isMultiple(of: 2) ? 16 : -16)))
        }
        return (day, hr, rr)
    }

    func testNightlyScoringKeepsConfirmedWhoop4LegacyIntervalsAfterRePairing() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            try register(registry, canonicalModel: "4.0")
            let input = night()
            try await seedBaseline(store, before: input.day)
            _ = try await store.insert(Streams(hr: input.hr), deviceId: canonical)
            let repo = Repository(deviceId: active)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)
            await engine.analyzeRecent(maxDays: 2, force: true)
            let emptyRows = try await store.dailyMetrics(deviceId: canonical + "-noop", from: input.day, to: input.day)
            let empty = try XCTUnwrap(emptyRows.first)
            XCTAssertNil(empty.avgHrv)
            XCTAssertNil(empty.recovery)
            _ = try await store.insert(Streams(rr: input.rr), deviceId: canonical)
            await engine.analyzeRecent(maxDays: 2, force: true)
            let rows = try await store.dailyMetrics(deviceId: canonical + "-noop",
                from: input.day, to: input.day)
            let scored = try XCTUnwrap(rows.first)
            XCTAssertGreaterThan(try XCTUnwrap(scored.avgHrv), 0)
            XCTAssertNotNil(scored.recovery)
        }
    }

    /// Per-beat precedence, not per-window: one labelled history beat far from the sleep must not blank
    /// the standard beats that cover the night itself.
    func testOneHistoryBeatDoesNotBlankTheStandardBeatsOfTheNight() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            try register(registry, canonicalModel: "5.0")
            let input = night()
            try await seedBaseline(store, before: input.day)
            let standard = input.rr.map { RRInterval(ts: $0.ts, rrMs: $0.rrMs, srcChannel: .whoop5Standard) }
            _ = try await store.insert(Streams(hr: input.hr, rr: standard), deviceId: canonical)
            let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            _ = try await store.insert(Streams(rr: [RRInterval(ts: midnight - 31 * 3_600,
                rrMs: 900, srcChannel: .whoop5Historical)]), deviceId: canonical)
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: canonical)
            await engine.analyzeRecent(maxDays: 2, force: true)
            let rows = try await store.dailyMetrics(deviceId: canonical + "-noop", from: input.day, to: input.day)
            let scored = try XCTUnwrap(rows.first)
            XCTAssertGreaterThan(scored.totalSleepMin ?? 0, 0)
            XCTAssertNotNil(scored.avgHrv, "standard beats nothing better covers must still be scored")
        }
    }

    func testSelfHealStagesFromUnlabelledAliasBeatsBeforeRepositoryAdoptsActiveDevice() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            try register(registry, canonicalModel: "WHOOP")
            let start = 1_700_000_000
            let duration = 6 * 3_600
            let hr = (0..<duration).map { HRSample(ts: start + $0, bpm: 52 + ($0 / 60) % 3) }
            let grav = (0..<duration).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
            _ = try await store.insert(Streams(hr: hr, gravity: grav), deviceId: canonical)
            // AppModel adopts the new identity asynchronously; the repository still holds my-whoop.
            let repo = Repository(deviceId: canonical)
            repo.setStoreForTesting(store)
            await repo.addManualNap(startTs: start, endTs: start + duration)
            let before = try await store.sleepSessions(deviceId: canonical + "-noop",
                from: start, to: start + duration, limit: 10)
            let baseline = try XCTUnwrap(before.first?.stagesJSON)
            let rr = (0..<duration).map { i in
                RRInterval(ts: start + i, rrMs: 1000 + Int(40 * sin(2 * Double.pi * Double(i) / 4)))
            }
            _ = try await store.insert(Streams(rr: rr), deviceId: canonical)
            let healed = await repo.selfHealEditedStages(from: start, to: start + duration)
            XCTAssertNotEqual(healed.first?.stagesJSON, baseline,
                              "unlabelled alias R-R is what this install always staged from, so self-heal uses it")
        }
    }
}
