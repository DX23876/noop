import XCTest
import Foundation
@testable import Strand

/// Pins the Apple GPS workout recorder's pure pieces (#524): distance accumulation, the precision-5
/// polyline codec (which must round-trip AND match Android `RouteMath` byte-for-byte so a route is
/// cross-platform), the untrusted-fix `TrackFilter` gate, and the on-device `RouteStore` round-trip.
/// All pure / UserDefaults-backed — no CoreLocation — so they run headless, mirroring the Android
/// `RouteMathTest` case for case where the platforms still share behaviour.
final class GpsRouteMathTests: XCTestCase {
    func testRouteJournalKeepsSegmentsAndActiveTime() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = ActiveRouteJournal(url: folder.appendingPathComponent("route.txt"))
        let points = [WorkoutRoutePoint(lat: 50, lon: 8, accuracyM: 3, tMs: 1000, segment: 0, activeSeconds: 0),
                      WorkoutRoutePoint(lat: 51, lon: 9, accuracyM: 3, tMs: 9000, segment: 1, activeSeconds: 2)]
        journal.append(measured: points)
        XCTAssertEqual(journal.loadMeasured().points, points)
        XCTAssertEqual(RouteMath.recordedMeters(journal.loadMeasured().points ?? []), 0)
    }

    func testRecordedDistanceNeverBridgesPauseOrRestore() {
        let points = [
            WorkoutRoutePoint(lat: 50, lon: 8, accuracyM: 3, tMs: 1000, segment: 0, activeSeconds: 0),
            WorkoutRoutePoint(lat: 50.001, lon: 8, accuracyM: 3, tMs: 2000, segment: 0, activeSeconds: 1),
            WorkoutRoutePoint(lat: 51, lon: 9, accuracyM: 3, tMs: 9000, segment: 1, activeSeconds: 2),
            WorkoutRoutePoint(lat: 51.001, lon: 9, accuracyM: 3, tMs: 10000, segment: 1, activeSeconds: 3)
        ]
        let measured = RouteMath.recordedMeters(points)
        XCTAssertEqual(measured, 222.39, accuracy: 0.1)
        let route = WorkoutRoute(polyline: "", distanceM: measured, points: points, segmentStarts: [0, 2])
        XCTAssertEqual(route.segments.map(\.count), [2, 2])
    }

    func testSportSpeedCeilingCanAcceptACyclingLeg() {
        let running = TrackFilter(maxSpeedMps: 12)
        let cycling = TrackFilter(maxSpeedMps: 45)
        let start = RawFix(lat: 50, lon: 8, accuracyM: 3, tMs: 1000)
        let moving = RawFix(lat: 50.00018, lon: 8, accuracyM: 3, tMs: 2000,
                            speedMps: 20, speedAccuracyMps: 0.2)
        XCTAssertNotNil(running.accept(start))
        XCTAssertNotNil(cycling.accept(start))
        XCTAssertNil(running.accept(moving))
        XCTAssertNotNil(cycling.accept(moving))
    }

    // Two points ~451 m apart near the Thames (the SAME fixtures Android `RouteMathTest` uses).
    private let a = RouteMath.LatLng(51.5033, -0.1196)
    private let b = RouteMath.LatLng(51.5007, -0.1246)

    // MARK: - Distance + pace (Android parity)

    func testHaversineKnownDistance() {
        XCTAssertEqual(RouteMath.haversineMeters(a, b), 451.0, accuracy: 20.0)
    }

    func testTotalDistanceSumsSegments() {
        let total = RouteMath.totalMeters([a, b, a])
        XCTAssertEqual(total, RouteMath.haversineMeters(a, b) * 2, accuracy: 1.0)
    }

    func testTotalDistanceEmptyOrSingleIsZero() {
        XCTAssertEqual(RouteMath.totalMeters([]), 0.0, accuracy: 0.0)
        XCTAssertEqual(RouteMath.totalMeters([a]), 0.0, accuracy: 0.0)
    }

    /// Distance accumulation as the recorder folds in fixes: a 4-point track's total equals the sum of
    /// its consecutive legs (the exact thing `GpsWorkoutRecorder.ingest` recomputes per batch).
    func testDistanceAccumulatesAcrossGrowingTrack() {
        let c = RouteMath.LatLng(51.4995, -0.1357)
        let d = RouteMath.LatLng(51.4980, -0.1400)
        var track: [RouteMath.LatLng] = []
        var running = 0.0
        for p in [a, b, c, d] {
            if let prev = track.last { running += RouteMath.haversineMeters(prev, p) }
            track.append(p)
            // The running sum kept incrementally must always equal a fresh full recompute.
            XCTAssertEqual(RouteMath.totalMeters(track), running, accuracy: 1e-6)
        }
        XCTAssertGreaterThan(running, 0)
    }

    func testPaceSecPerKm() {
        XCTAssertEqual(RouteMath.paceSecPerKm(meters: 1000, seconds: 300)!, 300.0, accuracy: 0.001)
        XCTAssertNil(RouteMath.paceSecPerKm(meters: 0, seconds: 300))
    }

    func testActiveElapsedSecondsExcludesCompletedPauses() {
        XCTAssertEqual(
            RouteMath.activeElapsedSeconds(startMs: 1_000, nowMs: 11_000, pausedDurationMs: 2_500),
            7.5,
            accuracy: 0.001
        )
    }

    // MARK: - Polyline codec (round-trip + cross-platform golden)

    func testPolylineRoundTrips() {
        let pts = [a, b, RouteMath.LatLng(51.4995, -0.1357)]
        let decoded = RouteMath.decode(RouteMath.encode(pts))
        XCTAssertEqual(decoded.count, pts.count)
        for i in pts.indices {
            XCTAssertEqual(decoded[i].lat, pts[i].lat, accuracy: 1e-5)
            XCTAssertEqual(decoded[i].lon, pts[i].lon, accuracy: 1e-5)
        }
    }

    func testEncodeEmptyIsEmptyString() {
        XCTAssertTrue(RouteMath.encode([]).isEmpty)
        XCTAssertTrue(RouteMath.decode("").isEmpty)
    }

    /// The canonical Google "Encoded Polyline Algorithm Format" reference example. Our encoder MUST
    /// produce this EXACT string — it's the contract that the Android encoder (same algorithm) and any
    /// external decoder agree on, so a route stored on one platform reads on the other.
    func testPolylineMatchesGoogleReferenceGolden() {
        let pts = [
            RouteMath.LatLng(38.5, -120.2),
            RouteMath.LatLng(40.7, -120.95),
            RouteMath.LatLng(43.252, -126.453),
        ]
        XCTAssertEqual(RouteMath.encode(pts), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        let back = RouteMath.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0].lat, 38.5, accuracy: 1e-5)
        XCTAssertEqual(back[2].lon, -126.453, accuracy: 1e-5)
    }

    /// A truncated / corrupt polyline must decode to whatever it can parse and stop cleanly — never crash
    /// or read past the buffer (the string is read back from disk, so it's untrusted).
    func testDecodeTruncatedStopsCleanly() {
        let good = RouteMath.encode([a, b])
        let truncated = String(good.dropLast())
        // Doesn't crash; yields at most the points it could fully parse.
        let decoded = RouteMath.decode(truncated)
        XCTAssertLessThanOrEqual(decoded.count, 2)
    }

    func testDecodeGarbageDoesNotCrash() {
        _ = RouteMath.decode("not-a-polyline-!!!")
        _ = RouteMath.decode("\u{0}\u{1}\u{2}")
    }

    // MARK: - TrackFilter (untrusted-fix gate)

    private func fix(_ lat: Double, _ lon: Double, acc: Double, t: Int64) -> RawFix {
        RawFix(lat: lat, lon: lon, accuracyM: acc, tMs: t)
    }

    func testFilterDropsLowAccuracyFixes() {
        let f = TrackFilter()
        XCTAssertNil(f.accept(fix(51.50, -0.12, acc: 80, t: 0)))   // > 50 m gate
        XCTAssertNotNil(f.accept(fix(51.50, -0.12, acc: 10, t: 0))) // good
    }

    func testFilterDropsInvalidNegativeAccuracy() {
        // CoreLocation reports a negative horizontalAccuracy for an invalid fix — must be rejected.
        XCTAssertNil(TrackFilter().accept(fix(51.50, -0.12, acc: -1, t: 0)))
    }

    func testFilterDropsCachedFixFromBeforeCaptureWindow() {
        let f = TrackFilter()
        XCTAssertNil(f.accept(fix(51.50036, -0.1000, acc: 8, t: 40_000), notBeforeMs: 100_000))
        XCTAssertNotNil(f.accept(fix(51.50000, -0.1000, acc: 5, t: 101_000), notBeforeMs: 100_000))
    }

    func testFilterDropsTeleportJumps() {
        let f = TrackFilter()
        XCTAssertNotNil(f.accept(fix(51.5000, -0.1200, acc: 5, t: 0)))
        // ~450 m in 1 s = 450 m/s — far above the ~12 m/s gate, so it's a GPS jump and is rejected.
        XCTAssertNil(f.accept(fix(51.5007, -0.1246, acc: 5, t: 1000)))
        // The same move over 60 s (~7.5 m/s) is a believable run pace and is accepted.
        XCTAssertNotNil(f.accept(fix(51.5007, -0.1246, acc: 5, t: 60_000)))
    }

    func testFilterRejectsOutOfRangeCoordinates() {
        XCTAssertNil(TrackFilter().accept(fix(120, 0, acc: 5, t: 0)))      // lat > 90
        XCTAssertNil(TrackFilter().accept(fix(0, 200, acc: 5, t: 0)))      // lon > 180
    }

    func testFilterDoesNotTurnStationaryAccuracyJitterIntoDistance() {
        let f = TrackFilter()
        // Roughly +8 m / -8 m around one stationary phone. The old filter accepted every five-second
        // hop as a plausible 3 m/s movement and accumulated about 40 m despite the 5 m uncertainty of
        // each endpoint. Every reported position remains within the combined accuracy circles.
        let stationaryJitter = [
            fix(51.50000, -0.1000, acc: 5, t: 0),
            fix(51.50007, -0.1000, acc: 5, t: 5_000),
            fix(51.49993, -0.1000, acc: 5, t: 10_000),
            fix(51.50007, -0.1000, acc: 5, t: 15_000),
        ]
        let accepted = stationaryJitter.compactMap { f.accept($0) }

        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(RouteMath.totalMeters(accepted), 0, accuracy: 0.01)
    }

    func testIndoorCoarseFixesWithoutMotionEvidenceDoNotCreate150Meters() {
        let filter = TrackFilter()
        // A phone in one room: only uncertain positions arrive, with no measured movement.
        // Frequent delivery avoids the recorder's existing >10-second route-segment gap protection.
        var fixes = (0...15).map { index in
            RawFix(lat: 51.5 + Double(index) * 0.00009, lon: -0.1,
                   accuracyM: 22.5, tMs: Int64(index) * 2_000)
        }
        // A briefly confident speed estimate must not connect back to an untrusted starting position.
        fixes.append(RawFix(lat: 51.501404, lon: -0.1, accuracyM: 22.5, tMs: 32_000,
                            speedMps: 0.8, speedAccuracyMps: 0.1))
        let points = fixes.compactMap { filter.accept($0) }
        XCTAssertEqual(RouteMath.totalMeters(points), 0, accuracy: 0.01,
                       "Uncertain indoor locations without motion evidence must not invent a route")
    }

    func testMinimalCoarsePositionJumpWithoutSpeedIsNotDistance() {
        let filter = TrackFilter()
        let fixes = [
            RawFix(lat: 51.5, lon: -0.1, accuracyM: 22.5, tMs: 0),
            RawFix(lat: 51.50045, lon: -0.1, accuracyM: 22.5, tMs: 5_000),
        ]
        XCTAssertEqual(RouteMath.totalMeters(fixes.compactMap { filter.accept($0) }), 0)
    }

    func testCoarsePositionIsRejectedEvenWithAConfidentSpeedEstimate() {
        let filter = TrackFilter()
        XCTAssertNil(filter.accept(RawFix(lat: 51.5, lon: -0.1, accuracyM: 40, tMs: 0,
                                         speedMps: 2, speedAccuracyMps: 0.1)))
    }

    func testPositionJumpMustAgreeWithMeasuredSpeed() {
        let filter = TrackFilter()
        XCTAssertNotNil(filter.accept(RawFix(lat: 51.5, lon: -0.1, accuracyM: 3, tMs: 0,
                                            speedMps: 1, speedAccuracyMps: 0.1)))
        // 50 m in 5 s is below the running ceiling, but not compatible with measured 1 m/s.
        XCTAssertNil(filter.accept(RawFix(lat: 51.50045, lon: -0.1, accuracyM: 3, tMs: 5_000,
                                         speedMps: 1, speedAccuracyMps: 0.1)))
    }

    func testPhoneModeRejectsCoordinateDriftEvenAtReportedGoodAccuracy() {
        let filter = TrackFilter(requiresMotionEvidence: true)
        let fixes = (0...15).map { index in
            RawFix(lat: 51.5 + Double(index) * 0.00009, lon: -0.1,
                   accuracyM: 5, tMs: Int64(index) * 2_000)
        }
        let points = fixes.compactMap { filter.accept($0) }
        XCTAssertTrue(points.isEmpty)
        XCTAssertEqual(RouteMath.totalMeters(points), 0)
    }

    func testPhoneModeStartsAtZeroThenRecordsReliableSlowWalking() {
        let filter = TrackFilter(requiresMotionEvidence: true)
        XCTAssertNil(filter.accept(RawFix(lat: 51.50135, lon: -0.1, accuracyM: 5, tMs: 0)))
        let start = RawFix(lat: 51.5, lon: -0.1, accuracyM: 20, tMs: 5_000,
                           speedMps: 0.5, speedAccuracyMps: 0.1)
        let first = filter.accept(start)
        XCTAssertNotNil(first)
        XCTAssertEqual(RouteMath.totalMeters([first].compactMap { $0 }), 0)
        let next = filter.accept(RawFix(lat: 51.500009, lon: -0.1, accuracyM: 20, tMs: 7_000,
                                       speedMps: 0.5, speedAccuracyMps: 0.1))
        XCTAssertEqual(RouteMath.totalMeters([first, next].compactMap { $0 }), 1, accuracy: 0.1)
    }

    func testPhoneModeAccurateZeroSpeedDoesNotAccumulateStationaryDrift() {
        let filter = TrackFilter(requiresMotionEvidence: true)
        let fixes = (0...15).map { index in
            RawFix(lat: 51.5 + Double(index) * 0.00009, lon: -0.1,
                   accuracyM: 5, tMs: Int64(index) * 2_000, speedMps: 0, speedAccuracyMps: 0.1)
        }
        XCTAssertEqual(RouteMath.totalMeters(fixes.compactMap { filter.accept($0) }), 0)
    }

    /// iPhone GNSS often reports a walking speed with an uncertainty as large as the speed itself. That
    /// is still measured motion, unlike indoor drift, so the walk counts once it clears the accuracy circles.
    func testPhoneModeCountsWalkingWithImpreciseSpeedBeyondTheAccuracyCircles() {
        let filter = TrackFilter(requiresMotionEvidence: true)
        let walk = (0...12).map { index in
            RawFix(lat: 51.5 + Double(index) * 0.0000108, lon: -0.1, accuracyM: 5,
                   tMs: Int64(index) * 1_000, speedMps: 1.2, speedAccuracyMps: 1.0)
        }
        let points = walk.compactMap { filter.accept($0) }
        XCTAssertEqual(points.count, 2, "only legs beyond the 10 m of combined uncertainty")
        XCTAssertEqual(RouteMath.totalMeters(points), 10.8, accuracy: 0.2)
        // The same drift without a valid speed, as indoor positioning reports it, stays at zero.
        let indoor = TrackFilter(requiresMotionEvidence: true)
        let drift = walk.map { RawFix(lat: $0.lat, lon: $0.lon, accuracyM: 5, tMs: $0.tMs,
                                      speedMps: -1, speedAccuracyMps: -1) }
        XCTAssertTrue(drift.compactMap { indoor.accept($0) }.isEmpty)
    }

    func testGapIsBridgedWhenTheSportCeilingExplainsTheJump() {
        let filter = TrackFilter(requiresMotionEvidence: true)
        let first = RawFix(lat: 51.5, lon: -0.1, accuracyM: 5, tMs: 0, speedMps: 1, speedAccuracyMps: 0.2)
        XCTAssertEqual(filter.admit(first), .anchored(RouteMath.LatLng(51.5, -0.1)))
        // 60 m in 20 s is more than the last measured 1 m/s explains, but the gap hides the pace walked.
        let after = RawFix(lat: 51.50054, lon: -0.1, accuracyM: 5, tMs: 20_000, speedMps: 1, speedAccuracyMps: 0.2)
        XCTAssertEqual(filter.admit(after, afterGap: true), .joined(RouteMath.LatLng(51.50054, -0.1)))
    }

    func testGapReanchorsWhenTheJumpCannotBeExplained() {
        let filter = TrackFilter()
        XCTAssertNotNil(filter.accept(RawFix(lat: 51.5, lon: -0.1, accuracyM: 5, tMs: 0)))
        // 150 m in 2 s exceeds the running ceiling: a reacquired fix, not a route.
        let jump = RawFix(lat: 51.50135, lon: -0.1, accuracyM: 5, tMs: 2_000)
        XCTAssertEqual(filter.admit(jump, afterGap: true), .anchored(RouteMath.LatLng(51.50135, -0.1)))
        // Without a gap the same jump is just rejected and the anchor stays.
        let steady = TrackFilter()
        XCTAssertNotNil(steady.accept(RawFix(lat: 51.5, lon: -0.1, accuracyM: 5, tMs: 0)))
        XCTAssertEqual(steady.admit(jump), .rejected)
    }

    func testLongGapBeyondTheBridgeLimitsReanchors() {
        let filter = TrackFilter()
        XCTAssertNotNil(filter.accept(RawFix(lat: 51.5, lon: -0.1, accuracyM: 5, tMs: 0)))
        // 250 m in 120 s is a plausible pace, yet beyond 200 m and 30 s nothing measured it.
        let far = RawFix(lat: 51.50225, lon: -0.1, accuracyM: 5, tMs: 120_000)
        XCTAssertEqual(filter.admit(far, afterGap: true), .anchored(RouteMath.LatLng(51.50225, -0.1)))
        // A short outage is bridged even beyond 200 m when it lasted no more than 30 s.
        let quick = TrackFilter(maxSpeedMps: 20)
        XCTAssertNotNil(quick.accept(RawFix(lat: 51.5, lon: -0.1, accuracyM: 5, tMs: 0)))
        let ride = RawFix(lat: 51.50225, lon: -0.1, accuracyM: 5, tMs: 25_000)
        XCTAssertEqual(quick.admit(ride, afterGap: true), .joined(RouteMath.LatLng(51.50225, -0.1)))
    }

    func testFilterEventuallyAcceptsRealSlowMovementBeyondUncertainty() {
        let f = TrackFilter()
        XCTAssertNotNil(f.accept(fix(51.50000, -0.1000, acc: 5, t: 0)))
        XCTAssertNil(f.accept(fix(51.50007, -0.1000, acc: 5, t: 5_000)))
        // The rejected point did not move the anchor. About 16 m from the start now clears the combined
        // 10 m uncertainty, so an ordinary slow walk is delayed rather than lost.
        XCTAssertNotNil(f.accept(fix(51.50014, -0.1000, acc: 5, t: 10_000)))
    }

    func testSystemStationaryFlagRejectsEvenLargePositionDrift() {
        let filter = TrackFilter()
        let start = RawFix(lat: 51.5, lon: -0.1, accuracyM: 5, tMs: 0, stationary: true)
        let drift = RawFix(lat: 51.50036, lon: -0.1, accuracyM: 5, tMs: 60_000, stationary: true)
        XCTAssertNotNil(filter.accept(start))
        XCTAssertNil(filter.accept(drift), "system-confirmed stillness must not become 40 m of distance")
    }

    func testAccurateZeroSpeedRejectsDriftBeforeSystemDeclaresStationary() {
        let filter = TrackFilter()
        let fixes = [0.0, 0.00007, -0.00007, 0.00036].enumerated().map { index, offset in
            RawFix(lat: 51.5 + offset, lon: -0.1, accuracyM: 5, tMs: Int64(index) * 5_000,
                   speedMps: 0, speedAccuracyMps: 0.1)
        }
        let points = fixes.compactMap { filter.accept($0) }
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(RouteMath.totalMeters(points), 0)
    }

    func testReliableSlowWalkingPreservesShortLegsAtPoorPositionalAccuracy() {
        let filter = TrackFilter()
        let fixes = (0..<5).map { index in
            RawFix(lat: 51.5 + Double(index) * 0.000009, lon: -0.1, accuracyM: 20,
                   tMs: Int64(index) * 2_000, speedMps: 0.5, speedAccuracyMps: 0.1)
        }
        let points = fixes.compactMap { filter.accept($0) }
        XCTAssertEqual(points.count, fixes.count, "walking must not wait for a 40 m displacement")
        XCTAssertEqual(RouteMath.totalMeters(points), 4, accuracy: 0.1)
    }

    func testReliableMotionPreservesSmallLoopInsteadOfCuttingCorners() {
        let filter = TrackFilter()
        let fixes = [
            RawFix(lat: 51.5, lon: -0.1, accuracyM: 20, tMs: 0, speedMps: 2, speedAccuracyMps: 0.2),
            RawFix(lat: 51.50009, lon: -0.1, accuracyM: 20, tMs: 5_000, speedMps: 2, speedAccuracyMps: 0.2),
            RawFix(lat: 51.50009, lon: -0.099856, accuracyM: 20, tMs: 10_000, speedMps: 2, speedAccuracyMps: 0.2),
            RawFix(lat: 51.5, lon: -0.099856, accuracyM: 20, tMs: 15_000, speedMps: 2, speedAccuracyMps: 0.2),
            RawFix(lat: 51.5, lon: -0.1, accuracyM: 20, tMs: 20_000, speedMps: 2, speedAccuracyMps: 0.2),
        ]
        let points = fixes.compactMap { filter.accept($0) }
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(RouteMath.totalMeters(points), 40, accuracy: 1)
    }

    func testMotionEvidenceNeverOverridesBadAccuracyOrTeleportGate() {
        let filter = TrackFilter()
        XCTAssertNotNil(filter.accept(RawFix(lat: 51.5, lon: -0.1, accuracyM: 5, tMs: 0)))
        XCTAssertNil(filter.accept(RawFix(lat: 51.50009, lon: -0.1, accuracyM: 51, tMs: 5_000,
                                         speedMps: 2, speedAccuracyMps: 0.1)))
        XCTAssertNil(filter.accept(RawFix(lat: 51.51, lon: -0.1, accuracyM: 5, tMs: 6_000,
                                         speedMps: 2, speedAccuracyMps: 0.1)))
    }

    func testInvalidOrUncertainSpeedDoesNotBypassJitterFallback() {
        for (speed, accuracy) in [(1.0, -1.0), (-1.0, 0.1), (Double.nan, 0.1), (1.0, Double.infinity), (0.5, 0.8)] {
            let filter = TrackFilter()
            XCTAssertNotNil(filter.accept(RawFix(lat: 51.5, lon: -0.1, accuracyM: 5, tMs: 0)))
            XCTAssertNil(filter.accept(RawFix(lat: 51.50007, lon: -0.1, accuracyM: 5, tMs: 5_000,
                                             speedMps: speed, speedAccuracyMps: accuracy)))
        }
    }

    func testDuplicateAndBackwardsTimesCannotBypassFiltering() {
        let filter = TrackFilter()
        XCTAssertNotNil(filter.accept(fix(51.5, -0.1, acc: 5, t: 10_000)))
        XCTAssertNil(filter.accept(fix(51.51, -0.1, acc: 5, t: 10_000)))
        XCTAssertNil(filter.accept(fix(51.51, -0.1, acc: 5, t: 9_000)))
        XCTAssertNotNil(filter.accept(fix(51.50018, -0.1, acc: 5, t: 15_000)))
    }

    func testRejectedStationaryUpdateStillOrdersSubsequentFixes() {
        let filter = TrackFilter()
        XCTAssertNotNil(filter.accept(fix(51.5, -0.1, acc: 5, t: 0)))
        XCTAssertNil(filter.accept(RawFix(lat: 51.50036, lon: -0.1, accuracyM: 5, tMs: 60_000, stationary: true)))
        XCTAssertNil(filter.accept(RawFix(lat: 51.50018, lon: -0.1, accuracyM: 5, tMs: 30_000,
                                         speedMps: 1, speedAccuracyMps: 0.1)))
    }

    func testNonfiniteAccuracyIsInvalid() {
        XCTAssertNil(TrackFilter().accept(fix(51.5, -0.1, acc: .nan, t: 0)))
        XCTAssertNil(TrackFilter().accept(fix(51.5, -0.1, acc: .infinity, t: 0)))
    }

    // MARK: - RouteStore (on-device side-store round-trip)

    private func freshDefaults() -> UserDefaults {
        let name = "test.workoutRoutes.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testRouteStoreRoundTrip() {
        let defaults = freshDefaults()
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
        let route = WorkoutRoute(polyline: RouteMath.encode([a, b]),
                                 distanceM: RouteMath.totalMeters([a, b]))
        RouteStore.store(route, startTs: 1_700_000_000, sport: "Running", into: defaults)
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults), route)
        // Removing it leaves no orphan.
        RouteStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
    }

    func testRouteStorePreservesOriginalPointMeasurements() {
        let defaults = freshDefaults()
        let points = [
            WorkoutRoutePoint(lat: a.lat, lon: a.lon, accuracyM: 3.2, tMs: 1_700_000_000_000),
            WorkoutRoutePoint(lat: b.lat, lon: b.lon, accuracyM: 7.8, tMs: 1_700_000_012_345),
        ]
        let route = WorkoutRoute(polyline: RouteMath.encode([a, b]), distanceM: 451, points: points)
        RouteStore.store(route, startTs: 1_700_000_000, sport: "Running", into: defaults)
        let loaded = RouteStore.loadWithPoints(startTs: 1_700_000_000, sport: "Running", from: defaults)
        XCTAssertEqual(loaded?.points, points)
        XCTAssertTrue(loaded?.hasExportableMeasurements == true)

        // The routes map itself stays the handful of bytes its cap assumes: points live in their own key,
        // so the every-read full decode never carries them and `load` hands back a drawable route only.
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults)?.points)
        let mapJSON = String(data: defaults.data(forKey: RouteStore.defaultsKey) ?? Data(), encoding: .utf8)
        XCTAssertFalse(mapJSON?.contains("accuracyM") ?? true, "points must not reach the routes map")

        // Deleting the session takes the points with it, so their key cannot outlive the route.
        RouteStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        XCTAssertNil(RouteStore.loadWithPoints(startTs: 1_700_000_000, sport: "Running", from: defaults))
        XCTAssertNil(RoutePointStore.load(for: RouteStore.key(startTs: 1_700_000_000, sport: "Running"),
                                          from: defaults))
    }

    func testLegacyRouteWithoutPointMeasurementsRemainsReadableButCannotExport() throws {
        let key = RouteStore.key(startTs: 1_700_000_000, sport: "Running")
        let legacyJSON = #"{"\#(key)":{"polyline":"abc","distanceM":123.0}}"#.data(using: .utf8)
        let loaded = RouteStore.decodeMap(legacyJSON)[key]
        XCTAssertEqual(loaded?.polyline, "abc")
        XCTAssertNil(loaded?.points)
        XCTAssertFalse(loaded?.hasExportableMeasurements ?? true)
    }

    // MARK: - Restoring an in-flight route (ActiveRouteJournal)

    /// The seam a restore creates is judged, not assumed. A fix the banked route could not have reached at
    /// running speed must be refused as a continuation, because joining it would add the jump to the
    /// distance and draw a straight line across ground never recorded. A plausible one is accepted.
    func testSeamAfterRestoreIsJudgedBySpeedNotAssumed() {
        let f = TrackFilter()
        let banked = WorkoutRoutePoint(lat: 51.5007, lon: -0.1246, accuracyM: 4, tMs: 1_000_000)
        // Two seconds later, a few metres on: a wearer still running.
        let near = fix(51.5008, -0.1246, acc: 4, t: banked.tMs + 2_000)
        XCTAssertTrue(f.couldFollow(near, from: banked.lat, banked.lon, at: banked.tMs))
        // Two minutes later, most of a degree of latitude away: nobody ran that.
        let far = fix(52.2000, -0.1246, acc: 4, t: banked.tMs + 120_000)
        XCTAssertFalse(f.couldFollow(far, from: banked.lat, banked.lon, at: banked.tMs))
        // A fix stamped at or before the banked point cannot follow it either.
        let backwards = fix(51.5008, -0.1246, acc: 4, t: banked.tMs)
        XCTAssertFalse(f.couldFollow(backwards, from: banked.lat, banked.lon, at: banked.tMs))
    }

    /// `ActiveRouteJournal` restores the track from the measured points, which is only sound while
    /// the filter hands back the fix's OWN coordinates. Pin that: if the gate ever smooths or snaps a fix,
    /// a restored route would diverge from the one already drawn, and this fires instead.
    func testFilterReturnsTheFixCoordinatesSoBankedPointsRebuildTheTrack() {
        let f = TrackFilter()
        let raw = fix(51.5007, -0.1246, acc: 4, t: 1_000)
        let accepted = f.accept(raw)
        XCTAssertEqual(accepted?.lat, raw.lat)
        XCTAssertEqual(accepted?.lon, raw.lon)
    }

    func testRouteMeasurementsRequireMonotonicValidTimesAndAccuracy() {
        let good = [
            WorkoutRoutePoint(lat: a.lat, lon: a.lon, accuracyM: 4, tMs: 1000),
            WorkoutRoutePoint(lat: b.lat, lon: b.lon, accuracyM: 8, tMs: 2000),
        ]
        XCTAssertTrue(WorkoutRoute(polyline: "", distanceM: 0, points: good).hasExportableMeasurements)
        let duplicateTime = [good[0], WorkoutRoutePoint(lat: b.lat, lon: b.lon, accuracyM: 8, tMs: 1000)]
        XCTAssertFalse(WorkoutRoute(polyline: "", distanceM: 0, points: duplicateTime).hasExportableMeasurements)
        let invalidAccuracy = [good[0], WorkoutRoutePoint(lat: b.lat, lon: b.lon, accuracyM: -1, tMs: 2000)]
        XCTAssertFalse(WorkoutRoute(polyline: "", distanceM: 0, points: invalidAccuracy).hasExportableMeasurements)
    }

    func testRouteStoreKeysBySportAndStart() {
        let defaults = freshDefaults()
        let run = WorkoutRoute(polyline: RouteMath.encode([a, b]), distanceM: 1)
        let walk = WorkoutRoute(polyline: RouteMath.encode([b, a]), distanceM: 2)
        // Same start second, different sport — must NOT collide.
        RouteStore.store(run, startTs: 1_700_000_000, sport: "Running", into: defaults)
        RouteStore.store(walk, startTs: 1_700_000_000, sport: "Walking", into: defaults)
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults), run)
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_000, sport: "Walking", from: defaults), walk)
    }

    func testRouteStoreRejectsEmptyPolyline() {
        let defaults = freshDefaults()
        // An honest "no route" must never be stored as an empty placeholder.
        RouteStore.store(WorkoutRoute(polyline: "", distanceM: 0),
                         startTs: 1_700_000_000, sport: "Running", into: defaults)
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
    }

    func testRouteStoreDropsNonFiniteDistanceOnDecode() {
        // A corrupt blob with a non-finite distance is dropped on read — never trust the persisted value.
        let dirty: [String: WorkoutRoute] = [
            RouteStore.key(startTs: 1, sport: "Running"): WorkoutRoute(polyline: "abc", distanceM: .nan),
            RouteStore.key(startTs: 2, sport: "Cycling"): WorkoutRoute(polyline: "def", distanceM: 1234),
        ]
        let data = RouteStore.encodeMap(dirty)
        let decoded = RouteStore.decodeMap(data)
        XCTAssertNil(decoded[RouteStore.key(startTs: 1, sport: "Running")])
        XCTAssertNotNil(decoded[RouteStore.key(startTs: 2, sport: "Cycling")])
    }

    func testRouteStoreEvictsOldestPastCap() {
        let defaults = freshDefaults()
        // Store cap + 5 routes; the oldest 5 (lowest startTs) must be evicted, newest kept.
        let total = RouteStore.maxRoutes + 5
        for i in 0..<total {
            RouteStore.store(WorkoutRoute(polyline: "abc", distanceM: Double(i)),
                             startTs: 1_000_000 + i, sport: "Running", into: defaults)
        }
        let map = RouteStore.loadMap(from: defaults)
        XCTAssertEqual(map.count, RouteStore.maxRoutes)
        // The 5 oldest are gone; a recent one survives.
        XCTAssertNil(map[RouteStore.key(startTs: 1_000_000, sport: "Running")])
        XCTAssertNotNil(map[RouteStore.key(startTs: 1_000_000 + total - 1, sport: "Running")])
    }

    // MARK: - Re-key on edit (#10)

    /// #10: editing a GPS workout's sport or start re-keys its DB row, so its route must move to the new
    /// natural key too or the detail view loses the route + distance. This pins the exact re-key sequence
    /// Repository.saveManualWorkout runs in the changed-key branch (load old, store new, remove old): the
    /// route ends up under the NEW key only, byte-identical, with no orphan left behind.
    func testRouteStoreReKeyOnNaturalKeyChangePreservesRoute() {
        let defaults = freshDefaults()
        let route = WorkoutRoute(polyline: RouteMath.encode([a, b]),
                                 distanceM: RouteMath.totalMeters([a, b]))
        // The original session's route, keyed by its old (startTs, sport).
        RouteStore.store(route, startTs: 1_700_000_000, sport: "Running", into: defaults)

        // Re-key to a new sport AND a new start, exactly as the save path does on an edit.
        if let old = RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults) {
            RouteStore.store(old, startTs: 1_700_000_500, sport: "Walking", into: defaults)
            RouteStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        }

        // Route lives under the NEW key, unchanged; the OLD key is clear (no orphan, no distance ghost).
        XCTAssertEqual(RouteStore.load(startTs: 1_700_000_500, sport: "Walking", from: defaults), route)
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults))
        XCTAssertEqual(RouteStore.loadMap(from: defaults).count, 1)
    }

    /// #10 guard: a workout with NO recorded route stays a clean no-op on edit. The load returns nil, so
    /// the save path's `if let` never stores or removes anything, and the side-store stays empty.
    func testRouteStoreReKeyNoRouteIsNoOp() {
        let defaults = freshDefaults()
        if let old = RouteStore.load(startTs: 1_700_000_000, sport: "Running", from: defaults) {
            RouteStore.store(old, startTs: 1_700_000_500, sport: "Walking", into: defaults)
            RouteStore.remove(startTs: 1_700_000_000, sport: "Running", from: defaults)
        }
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_500, sport: "Walking", from: defaults))
        XCTAssertTrue(RouteStore.loadMap(from: defaults).isEmpty)
    }

    // MARK: - #1205: imported GPS route lands under the key WorkoutDetailView loads

    /// #1205: a route imported from Apple Health (HKWorkoutRoute) or Health Connect
    /// (ExerciseRouteResult.Data) is stored via `RouteStore.store` under the workout's natural
    /// key (startTs, sport). `WorkoutDetailView.load()` reads from that same key, so the imported
    /// route appears on the detail screen with no UI change. This test pins that contract: the
    /// store/load round-trip must survive under the exact key pair an imported workout carries.
    func testImportedRouteRoundTripsUnderWorkoutNaturalKey() {
        let defaults = freshDefaults()
        let startTs = 1_700_000_000
        let sport = "Running"
        // Simulate what HealthKitBridge.collectWorkouts does after fetching an HKWorkoutRoute:
        // encode the GPS points and store the resulting WorkoutRoute under the workout's key.
        let points = [a, b, RouteMath.LatLng(51.4995, -0.1357)]
        let route = WorkoutRoute(polyline: RouteMath.encode(points),
                                 distanceM: RouteMath.totalMeters(points))
        RouteStore.store(route, startTs: startTs, sport: sport, into: defaults)
        // WorkoutDetailView.load() reads from the same key and decodes the polyline.
        let loaded = RouteStore.load(startTs: startTs, sport: sport, from: defaults)
        XCTAssertEqual(loaded, route)
        let decoded = RouteMath.decode(loaded?.polyline ?? "")
        XCTAssertEqual(decoded.count, points.count)
        for i in points.indices {
            XCTAssertEqual(decoded[i].lat, points[i].lat, accuracy: 1e-5)
            XCTAssertEqual(decoded[i].lon, points[i].lon, accuracy: 1e-5)
        }
    }

    /// The batched write an import uses must be indistinguishable from a run of single stores.
    ///
    /// `collectWorkouts` collects every imported route and calls `storeAll` once, because `store`
    /// rewrites the whole capped map per call and an import calls it per workout. This pins that the
    /// shortcut costs nothing: same keys, same values, and the same oldest-first eviction when the batch
    /// overflows [RouteStore.maxRoutes].
    func testStoreAllMatchesRepeatedSingleStores() {
        let sport = "Running"
        func route(_ i: Int) -> WorkoutRoute {
            let pts = [RouteMath.LatLng(51.5 + Double(i) / 1000, -0.12),
                       RouteMath.LatLng(51.5 + Double(i) / 1000, -0.13)]
            return WorkoutRoute(polyline: RouteMath.encode(pts), distanceM: RouteMath.totalMeters(pts))
        }
        // More than the cap, so eviction is exercised rather than assumed.
        let n = RouteStore.maxRoutes + 25
        let entries = (0..<n).map { (route: route($0), startTs: 1_700_000_000 + $0 * 3_600, sport: sport) }

        let oneByOne = freshDefaults()
        for e in entries { RouteStore.store(e.route, startTs: e.startTs, sport: e.sport, into: oneByOne) }

        let batched = freshDefaults()
        RouteStore.storeAll(entries, into: batched)

        XCTAssertEqual(RouteStore.loadMap(from: batched), RouteStore.loadMap(from: oneByOne),
                       "batching must not change which routes survive, nor their values")
        XCTAssertEqual(RouteStore.loadMap(from: batched).count, RouteStore.maxRoutes)
        // The newest survive and the oldest are gone, in both.
        XCTAssertNotNil(RouteStore.load(startTs: entries.last!.startTs, sport: sport, from: batched))
        XCTAssertNil(RouteStore.load(startTs: entries.first!.startTs, sport: sport, from: batched))
    }

    /// An empty batch must not touch the store at all, so an import with no routes writes nothing.
    func testStoreAllWithNoRoutesWritesNothing() {
        let defaults = freshDefaults()
        RouteStore.store(WorkoutRoute(polyline: "abc", distanceM: 1), startTs: 1_700_000_000,
                         sport: "Running", into: defaults)
        let before = RouteStore.loadMap(from: defaults)
        RouteStore.storeAll([], into: defaults)
        XCTAssertEqual(RouteStore.loadMap(from: defaults), before)
    }

    /// #1205: a workout with no GPS route (e.g. a gym session imported from Apple Health) must
    /// load nil from RouteStore, so WorkoutDetailView shows no map card — exactly as before.
    func testImportedWorkoutWithoutRouteLoadsNil() {
        let defaults = freshDefaults()
        XCTAssertNil(RouteStore.load(startTs: 1_700_000_000, sport: "Strength Training", from: defaults))
    }
}
