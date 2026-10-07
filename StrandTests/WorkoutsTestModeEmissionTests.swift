import XCTest
import CoreLocation
import StrandAnalytics
@testable import Strand

/// Proves the Workouts & GPS test mode (Test Centre) is GENUINELY zero-cost when off: the GPS-fix emitter in
/// GpsWorkoutRecorder is gated behind TestCentre.active(.workouts), so with the mode OFF an accepted fix
/// writes ZERO .workouts-tagged lines, and with it ON it writes a GPS-fix line. The CRITICAL property the
/// spec calls out is the mode-off path emitting nothing tagged. Twin intent of ConnectionTestModeEmissionTests.
@MainActor
final class WorkoutsTestModeEmissionTests: XCTestCase {
    private var testJournalFolders: [URL] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "testcentre.active.workouts")
        UserDefaults.standard.removeObject(forKey: "testcentre.active.master")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "testcentre.active.workouts")
        UserDefaults.standard.removeObject(forKey: "testcentre.active.master")
        for folder in testJournalFolders { try? FileManager.default.removeItem(at: folder) }
        testJournalFolders.removeAll()
        super.tearDown()
    }

    /// Tests must never clear the production in-flight workout's default journal.
    private func makeRecorder() -> GpsWorkoutRecorder {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        testJournalFolders.append(folder)
        let recorder = GpsWorkoutRecorder()
        recorder.journal = ActiveRouteJournal(url: folder.appendingPathComponent("route.txt"))
        return recorder
    }

    // Two well-separated, high-accuracy fixes a few seconds apart: the TrackFilter accepts both, so `ingest`
    // reaches the GPS-fix emit branch (two accepted points → a non-zero distance).
    private func fixes() -> [CLLocation] {
        let now = Date()
        let a = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5000, longitude: -0.1000),
                           altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now)
        let b = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5003, longitude: -0.1000),
                           altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                           timestamp: now.addingTimeInterval(3))
        return [a, b]
    }

    func testModeOffEmitsZeroWorkoutsLines() {
        XCTAssertFalse(TestCentre.active(.workouts))
        var captured: [String] = []
        let rec = makeRecorder()
        rec.workoutsLog = { captured.append($0) }
        rec.start(startMs: Int64(Date().timeIntervalSince1970 * 1000))
        rec.receiveLocations(fixes())
        XCTAssertTrue(captured.isEmpty, "mode OFF must emit zero .workouts lines, got \(captured)")
        rec.stop()
    }

    func testModeOnEmitsAGpsFixLine() {
        TestCentre.activate(.workouts)
        defer { TestCentre.deactivate(.workouts) }
        var captured: [String] = []
        let rec = makeRecorder()
        rec.workoutsLog = { captured.append($0) }
        rec.start(startMs: Int64(Date().timeIntervalSince1970 * 1000))
        rec.receiveLocations(fixes())
        XCTAssertFalse(captured.isEmpty, "mode ON must emit a GPS-fix line")
        XCTAssertTrue(captured.last?.hasPrefix("gps rawFixes=") ?? false, captured.last ?? "nil")
        let fixLines = captured.filter { $0.hasPrefix("gpsfix ") }
        XCTAssertEqual(fixLines.count, 2, "one line per raw fix")
        XCTAssertTrue(fixLines.allSatisfy { !$0.contains("51.5") }, "fix lines must never carry a coordinate")
        rec.stop()
    }

    /// Core Location may emit a cached fix immediately after updates start. It predates the workout and
    /// must not become the route's first point: otherwise the first current fix can turn a stationary
    /// session into tens of metres of invented movement.
    func testCachedFixFromBeforeWorkoutDoesNotCreateStationaryDistance() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let cached = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 51.50036, longitude: -0.1000),
            altitude: 0,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            timestamp: start.addingTimeInterval(-60)
        )
        let current = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 51.5000, longitude: -0.1000),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: start.addingTimeInterval(1)
        )

        let recorder = makeRecorder()
        recorder.start(startMs: startMs)
        recorder.receiveLocations([cached, current])
        defer { recorder.stop() }

        XCTAssertEqual(recorder.pointCount, 1)
        XCTAssertEqual(recorder.distanceM, 0, accuracy: 0.01)
    }

    func testIndoorDriftDoesNotReachDisplayedOrRecordedDistance() {
        let start = Date.now
        let recorder = GpsWorkoutRecorder()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        recorder.journal = ActiveRouteJournal(url: folder.appendingPathComponent("route.txt"))
        defer { recorder.stop(); try? FileManager.default.removeItem(at: folder) }
        recorder.start(startMs: Int64(start.timeIntervalSince1970 * 1000))
        var emittedDistances: [Double] = []
        recorder.onAcceptedPoint = { _, distance in emittedDistances.append(distance) }
        let locations = (0...15).map { index in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5 + Double(index) * 0.00009,
                                                          longitude: -0.1),
                       altitude: 0, horizontalAccuracy: 22.5, verticalAccuracy: 5,
                       timestamp: start.addingTimeInterval(Double(index) * 2))
        }
        recorder.receiveLocations(locations)
        XCTAssertEqual(recorder.distanceM, 0, accuracy: 0.01)
        XCTAssertTrue(emittedDistances.allSatisfy { $0 == 0 })
        XCTAssertNil(recorder.capturedRoute())
        XCTAssertEqual(recorder.pointCount, 0)
    }

    func testUnavailableOrApproximateLocationsCannotStartARoute() {
        for approximate in [false, true] {
            let start = Date.now
            let recorder = GpsWorkoutRecorder()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            recorder.journal = ActiveRouteJournal(url: folder.appendingPathComponent("route.txt"))
            defer { recorder.stop(); try? FileManager.default.removeItem(at: folder) }
            recorder.start(startMs: Int64(start.timeIntervalSince1970 * 1000))
            recorder.receiveLocations(fixes(), locationUnavailable: !approximate, accuracyLimited: approximate)
            XCTAssertEqual(recorder.distanceM, 0)
            XCTAssertEqual(recorder.pointCount, 0)
            XCTAssertEqual(recorder.state, .acquiring)
            XCTAssertNil(recorder.capturedRoute())
        }
    }

    func testSignalLossFreezesDistanceAndAnUnexplainedRecoveryOnlySetsANewAnchor() throws {
        let start = Date.now
        let recorder = makeRecorder()
        defer { recorder.stop() }
        recorder.start(startMs: Int64(start.timeIntervalSince1970 * 1000))
        func location(_ latitude: Double, seconds: Double, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -0.1),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                       timestamp: start.addingTimeInterval(seconds))
        }
        recorder.receiveLocations([location(51.5, seconds: 0), location(51.50018, seconds: 5)])
        let retained = recorder.distanceM
        XCTAssertEqual(retained, 20, accuracy: 0.1)

        recorder.receiveLocations([], locationUnavailable: true)
        XCTAssertEqual(recorder.state, .failed)
        XCTAssertEqual(recorder.distanceM, retained)
        // A newly acquired position 150 m away two seconds later is not a measured route from the old anchor.
        recorder.receiveLocations([location(51.50135, seconds: 7)])
        XCTAssertEqual(recorder.distanceM, retained)
        recorder.receiveLocations([location(51.50153, seconds: 12)])
        XCTAssertEqual(recorder.distanceM, retained + 20, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(recorder.capturedRoute()).segments.map(\.count), [2, 2])
    }

    /// OpenTracks bridges an outage the movement can explain. A tunnel walked at running pace must not
    /// erase its length or split the route.
    func testAnOutageTheMovementExplainsIsBridged() throws {
        let start = Date.now
        let recorder = makeRecorder()
        defer { recorder.stop() }
        recorder.start(startMs: Int64(start.timeIntervalSince1970 * 1000))
        func location(_ latitude: Double, seconds: Double) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -0.1),
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                       timestamp: start.addingTimeInterval(seconds))
        }
        recorder.receiveLocations([location(51.5, seconds: 0), location(51.50018, seconds: 5)])
        recorder.receiveLocations([], locationUnavailable: true)
        // 60 m in 20 s after the outage: 3 m/s, well inside the running ceiling.
        recorder.receiveLocations([location(51.50072, seconds: 25)])
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(recorder.distanceM, 80, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(recorder.capturedRoute()).segments.map(\.count), [3])
    }

    func testAnUnavailableDeliveryWithCoordinatesCannotBridgeRecovery() {
        let start = Date.now
        let recorder = GpsWorkoutRecorder()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        recorder.journal = ActiveRouteJournal(url: folder.appendingPathComponent("route.txt"))
        defer { recorder.stop(); try? FileManager.default.removeItem(at: folder) }
        recorder.start(startMs: Int64(start.timeIntervalSince1970 * 1000))
        recorder.receiveLocations(fixes())
        let retained = recorder.distanceM
        let recovery = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.50135, longitude: -0.1),
                                    altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                    timestamp: start.addingTimeInterval(8))
        recorder.receiveLocations([recovery], locationUnavailable: true)
        XCTAssertEqual(recorder.distanceM, retained)
        XCTAssertEqual(recorder.state, .failed)
        recorder.receiveLocations([recovery])
        XCTAssertEqual(recorder.distanceM, retained)
    }

    func testOneUntrustedFixIsSkippedButARunOfThemIsAnOutage() {
        let start = Date.now
        let recorder = makeRecorder()
        defer { recorder.stop() }
        recorder.start(startMs: Int64(start.timeIntervalSince1970 * 1000))
        func uncertain(_ seconds: Double) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.50135, longitude: -0.1),
                       altitude: 0, horizontalAccuracy: 22.5, verticalAccuracy: 5,
                       timestamp: start.addingTimeInterval(seconds))
        }
        let walk = [0.0, 3.0].map { seconds in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5 + seconds * 0.0001, longitude: -0.1),
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                       timestamp: start.addingTimeInterval(seconds))
        }
        recorder.receiveLocations(walk + [uncertain(5)])
        XCTAssertEqual(recorder.state, .recording, "a single bad fix must not report a lost signal")
        XCTAssertEqual(recorder.pointCount, 2)
        XCTAssertEqual(recorder.distanceM, 33.36, accuracy: 0.1)
        recorder.receiveLocations((6...19).map { uncertain(Double($0)) })
        XCTAssertEqual(recorder.state, .failed, "15 s without a usable fix is a lost signal")
        XCTAssertEqual(recorder.distanceM, 33.36, accuracy: 0.1)
    }

    /// Core Location goes quiet while the walker stands at a crossing. A silence the filter bridges is a
    /// measured leg: it must not mark the kilometre as a measurement gap (seen on two 2026-10-07 walks,
    /// one continuous route with every split flagged). An unexplained jump still is one.
    func testBridgedSilenceIsNoMeasurementGapButAnUnexplainedJumpIs() {
        let start = Date.now.addingTimeInterval(-300)
        let recorder = makeRecorder()
        defer { recorder.stop() }
        recorder.start(startMs: Int64(start.timeIntervalSince1970 * 1000))
        var interruptions = 0
        recorder.onInterruption = { interruptions += 1 }
        func fix(_ seconds: Double, north metres: Double) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5 + metres / 111_195, longitude: -0.1),
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                       timestamp: start.addingTimeInterval(seconds))
        }
        recorder.receiveLocations([fix(1, north: 0), fix(6, north: 15), fix(11, north: 30)])
        // 40 s without any delivery, then the walk resumes 30 m further on.
        recorder.receiveLocations([fix(51, north: 60), fix(56, north: 75)])
        XCTAssertEqual(interruptions, 0, "a bridged silence is a measured leg")
        XCTAssertEqual(recorder.capturedRoute()?.segmentStarts, [0])
        XCTAssertEqual(recorder.distanceM, 75, accuracy: 0.5)
        // 60 s later 2 km away: faster than the sport allows, so the route breaks there.
        recorder.receiveLocations([fix(116, north: 2075), fix(121, north: 2090)])
        XCTAssertEqual(interruptions, 1)
        XCTAssertEqual(recorder.capturedRoute()?.segmentStarts, [0, 5])
        XCTAssertEqual(recorder.distanceM, 90, accuracy: 0.5)
    }
}
