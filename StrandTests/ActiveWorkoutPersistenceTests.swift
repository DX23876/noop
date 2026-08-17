import XCTest
import Foundation
import WhoopProtocol
@testable import Strand

/// Pins the durable manual-workout codec (#529): the persist -> rehydrate round-trip that lets a
/// manually-started session survive iOS killing the app mid-session so it can still be ended and saved.
/// Pure + `UserDefaults`-backed, mirroring the Android `ActiveWorkoutPersistenceTest` case for case.
final class ActiveWorkoutPersistenceTests: XCTestCase {

    private func sample(_ ts: Int, _ bpm: Int) -> HRSample { HRSample(ts: ts, bpm: bpm) }

    private func snapshot(
        startSec: Int = 1_700_000_000,
        sport: String = "Tennis",
        samples: [HRSample] = [HRSample(ts: 1_700_000_001, bpm: 120), HRSample(ts: 1_700_000_061, bpm: 145)],
        avgHr: Int = 133,
        peakHr: Int = 145,
        liveStrain: Double = 8.4,
        targetZone: Int? = nil
    ) -> ActiveWorkoutPersistence.Snapshot {
        ActiveWorkoutPersistence.Snapshot(startSec: startSec, sport: sport, samples: samples,
                                          avgHr: avgHr, peakHr: peakHr, liveStrain: liveStrain,
                                          targetZone: targetZone)
    }

    /// A throwaway, isolated defaults suite so the test never touches the real store.
    private func freshDefaults() -> UserDefaults {
        let name = "test.activeWorkout.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - pure codec round-trip

    func testEncodeDecodeRoundTripsEveryField() {
        let original = snapshot()
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripWithNoSamples() {
        // A session that started but hasn't captured a sample yet (strap not streaming) must still
        // persist + rehydrate — otherwise a kill right after Start loses the start time.
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(samples: [], avgHr: 0, peakHr: 0, liveStrain: 0)))
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.samples.isEmpty)
        XCTAssertEqual(decoded!.startSec, 1_700_000_000)
        XCTAssertEqual(decoded!.sport, "Tennis")
    }

    func testRoundTripSportNameWithSpacesPreserved() {
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(sport: "Traditional Strength Training")))
        XCTAssertEqual(decoded!.sport, "Traditional Strength Training")
    }

    func testTargetZoneRoundTripsAndInvalidValueBecomesNoCoach() {
        XCTAssertEqual(ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(targetZone: 3)))?.targetZone, 3)
        XCTAssertNil(ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(targetZone: 9)))?.targetZone)
    }

    func testSnapshotFromOlderBuildWithoutTargetZoneStillDecodes() throws {
        struct LegacySnapshot: Codable {
            var startSec: Int
            var sport: String
            var samples: [HRSample]
            var avgHr: Int
            var peakHr: Int
            var liveStrain: Double
        }
        let legacy = LegacySnapshot(startSec: 1_700_000_000, sport: "Cycling", samples: [],
                                    avgHr: 0, peakHr: 0, liveStrain: 0)
        let decoded = ActiveWorkoutPersistence.decode(try JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded?.sport, "Cycling")
        XCTAssertNil(decoded?.targetZone)
    }

    func testLastTargetPreferenceIsValidatedAndCanReturnToNoCoach() {
        let defaults = freshDefaults()
        XCTAssertNil(ZoneTrainingPrefs.lastTargetZone(defaults))
        ZoneTrainingPrefs.setLastTargetZone(4, defaults)
        XCTAssertEqual(ZoneTrainingPrefs.lastTargetZone(defaults), 4)
        defaults.set(99, forKey: ZoneTrainingPrefs.lastTargetZoneKey)
        XCTAssertNil(ZoneTrainingPrefs.lastTargetZone(defaults))
        ZoneTrainingPrefs.setLastTargetZone(nil, defaults)
        XCTAssertNil(defaults.object(forKey: ZoneTrainingPrefs.lastTargetZoneKey))
    }

    // MARK: - UserDefaults store / load / clear

    func testStoreLoadClearRoundTrip() {
        let defaults = freshDefaults()
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))   // nothing yet
        let snap = snapshot()
        ActiveWorkoutPersistence.store(snap, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), snap)
        // Ending the session clears it — a relaunch then rehydrates nothing.
        ActiveWorkoutPersistence.clear(from: defaults)
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))
    }

    func testStoreOverwritesPreviousSnapshot() {
        // Each captured sample re-stores; the latest write wins (mirrors the per-sample persist).
        let defaults = freshDefaults()
        ActiveWorkoutPersistence.store(snapshot(samples: [sample(1_700_000_001, 120)], avgHr: 120, peakHr: 120),
                                       into: defaults)
        let later = snapshot(samples: [sample(1_700_000_001, 120), sample(1_700_000_061, 150)],
                             avgHr: 135, peakHr: 150, liveStrain: 9.1)
        ActiveWorkoutPersistence.store(later, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), later)
    }

    // MARK: - honest failure (no revived bogus card)

    func testDecodeNilOrEmptyIsNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(nil))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data()))
    }

    func testDecodeGarbageIsNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("not json".utf8)))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("{\"unexpected\":1}".utf8)))
    }

    func testDecodeRejectsNonPositiveStart() {
        let bad = snapshot(startSec: 0)
        XCTAssertNil(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(bad)))
    }

    // MARK: - bound-checked untrusted samples

    func testDecodeDropsOutOfRangeSamples() {
        // A corrupt blob with a bpm=0, bpm=400, and ts<=0 sample — only the in-range one survives.
        let dirty = snapshot(samples: [
            sample(1_700_000_001, 150),   // good
            sample(1_700_000_002, 0),     // bpm 0 — rejected
            sample(1_700_000_003, 400),   // bpm out of range — rejected
            sample(0, 120),               // ts <= 0 — rejected
        ])
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertEqual(decoded?.samples, [sample(1_700_000_001, 150)])
    }

    func testDecodeClampsNegativeDerivedStats() {
        let dirty = snapshot(samples: [], avgHr: -5, peakHr: -9, liveStrain: -3)
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.avgHr, 0)
        XCTAssertEqual(decoded!.peakHr, 0)
        XCTAssertEqual(decoded!.liveStrain, 0, accuracy: 1e-9)
    }
}
