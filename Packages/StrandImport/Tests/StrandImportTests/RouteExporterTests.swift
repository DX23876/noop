import XCTest
@testable import StrandImport

/// RouteExporter (GPX/FIT) is validated by ROUND-TRIP through ``ActivityFileImporter``: a route + metadata
/// is exported, then re-parsed, and the decoded track/summary must match. This pins the encoders against
/// the app's own decoders (the same ones that read real Strava/Garmin files), so a byte-layout regression
/// in either format is caught in `swift-packages` CI. The Kotlin twin (`RouteExportTest`) asserts the same.
final class RouteExporterTests: XCTestCase {

    func testRecordedGpxPreservesActualTimesAndSegmentGaps() {
        let points = [RoutePoint(lat: 50, lon: 8), RoutePoint(lat: 50.001, lon: 8),
                      RoutePoint(lat: 51, lon: 9), RoutePoint(lat: 51.001, lon: 9)]
        let gpx = RouteExporter.buildGpx(route: points, startTs: 1_723_000_000,
            endTs: 1_723_000_100, sport: "running",
            recordedTimes: [1_723_000_010, 1_723_000_020, 1_723_000_080, 1_723_000_090],
            segmentStarts: [0, 2])
        XCTAssertEqual(gpx.components(separatedBy: "<trkseg>").count - 1, 2)
        XCTAssertTrue(gpx.contains(RouteExporter.iso(1_723_000_020)))
        XCTAssertTrue(gpx.contains(RouteExporter.iso(1_723_000_080)))
        XCTAssertFalse(gpx.contains(RouteExporter.iso(1_723_000_100)))
    }

    private let route = [
        RoutePoint(lat: 37.334900, lon: -122.009000),
        RoutePoint(lat: 37.335200, lon: -122.008400),
        RoutePoint(lat: 37.335900, lon: -122.007700),
        RoutePoint(lat: 37.336500, lon: -122.006900),
    ]
    private let startTs = 1_723_000_000
    private let endTs = 1_723_001_800 // +30 min

    func testGpxRoundTripsThroughTheImporter() {
        let data = RouteExporter.render(.gpx, route: route, startTs: startTs, endTs: endTs,
                                        sport: "running", distanceM: 1234.5)
        XCTAssertEqual(ActivityFileImporter.detectFormat(data: data), .gpx)
        let a = ActivityFileImporter.parse(data: data, filename: "route.gpx").activity
        XCTAssertNotNil(a)
        XCTAssertEqual(a!.route.count, route.count)
        for i in route.indices {
            XCTAssertEqual(a!.route[i].lat, route[i].lat, accuracy: 1e-5)
            XCTAssertEqual(a!.route[i].lon, route[i].lon, accuracy: 1e-5)
        }
        XCTAssertEqual(Int(a!.start.timeIntervalSince1970), startTs)
        XCTAssertEqual(Int(a!.end.timeIntervalSince1970), endTs)
    }

    func testFitRoundTripsThroughTheImporter() {
        let data = RouteExporter.render(.fit, route: route, startTs: startTs, endTs: endTs,
                                        sport: "cycling", distanceM: 1234.5, energyKcal: 210, avgHr: 142, maxHr: 171)
        XCTAssertEqual(ActivityFileImporter.detectFormat(data: data), .fit)
        let a = ActivityFileImporter.parse(data: data, filename: "route.fit").activity
        XCTAssertNotNil(a)
        XCTAssertEqual(a!.route.count, route.count)
        for i in route.indices {
            XCTAssertEqual(a!.route[i].lat, route[i].lat, accuracy: 1e-5)
            XCTAssertEqual(a!.route[i].lon, route[i].lon, accuracy: 1e-5)
        }
        XCTAssertEqual(a!.sport?.lowercased().contains("cycl"), true)
        XCTAssertEqual(a!.distanceM ?? 0, 1234.5, accuracy: 0.5)
        XCTAssertEqual(a!.energyKcal ?? 0, 210, accuracy: 0.5)
        XCTAssertEqual(a!.avgHr, 142)
        XCTAssertEqual(a!.maxHr, 171)
        XCTAssertEqual(Int(a!.start.timeIntervalSince1970), startTs)
        XCTAssertEqual(Int(a!.end.timeIntervalSince1970), endTs)
    }

    /// Measured heights travel in both formats and come back through the importer; a point without one
    /// stays without one instead of reading as sea level.
    func testElevationsRoundTripInGpxAndFit() {
        // Spelled out: the one-line ternary over nil and arithmetic timed out the type checker on CI runners.
        let heights: [Double?] = (0..<route.count).map { i -> Double? in
            if i == 1 { return nil }
            return 400.0 + Double(i) * 4.0
        }
        for format in [RouteExporter.Format.gpx, .fit] {
            let data = RouteExporter.render(format, route: route, startTs: startTs, endTs: endTs,
                                            sport: "running", distanceM: 1234.5, elevations: heights)
            let a = ActivityFileImporter.parse(data: data, filename: "route.\(format.ext)").activity
            XCTAssertEqual(a?.route.count, route.count)
            XCTAssertEqual(a?.ascentM ?? 0, Double(route.count - 1) * 4, accuracy: 0.5, "\(format)")
        }
        let gpx = RouteExporter.buildGpx(route: route, startTs: startTs, endTs: endTs, sport: "running",
                                         elevations: heights)
        XCTAssertEqual(gpx.components(separatedBy: "<ele>").count - 1, route.count - 1)
        XCTAssertTrue(gpx.contains("<ele>400.0</ele><time>"))
    }

    func testNoElevationsWritesNone() {
        let gpx = RouteExporter.buildGpx(route: route, startTs: startTs, endTs: endTs, sport: "running",
                                         elevations: Array(repeating: nil, count: route.count))
        XCTAssertFalse(gpx.contains("<ele>"))
        let mismatched = RouteExporter.buildGpx(route: route, startTs: startTs, endTs: endTs, sport: "running",
                                                elevations: [100])
        XCTAssertFalse(mismatched.contains("<ele>"))
        XCTAssertEqual(RouteExporter.fitAltitude(nil), 0xFFFF)
        XCTAssertEqual(RouteExporter.fitAltitude(0), 2500)
        XCTAssertEqual(RouteExporter.fitAltitude(-600), 0xFFFF)
    }

    func testFitHasValidHeaderAndCrc() {
        let bytes = [UInt8](RouteExporter.render(.fit, route: route, startTs: startTs, endTs: endTs, sport: "run"))
        XCTAssertEqual(Int(bytes[0]), 12)                  // header size
        XCTAssertEqual(Array(bytes[8...11]), Array(".FIT".utf8)) // ".FIT"
        let dataSize = Int(bytes[4]) | (Int(bytes[5]) << 8) | (Int(bytes[6]) << 16) | (Int(bytes[7]) << 24)
        XCTAssertEqual(bytes.count, 12 + dataSize + 2)     // header + body + 2-byte CRC
        let crc = Int(bytes[bytes.count - 2]) | (Int(bytes[bytes.count - 1]) << 8)
        XCTAssertEqual(RouteExporter.fitCrc(Array(bytes[0..<(bytes.count - 2)])), crc)
    }

    func testFitSemicircleHalfTiesRoundAwayFromZeroOnBothPlatforms() {
        // One-point FIT layout: record data starts at byte 50, then local header (1), timestamp (4),
        // and signed little-endian latitude (4). Exercise exact negative half-ties plus positive controls.
        let semicirclesPerDegree = 2_147_483_648.0 / 180.0
        let targets = [-1.5, -0.5, 0.5, 1.5]
        let expected: [Int32] = [-2, -1, 1, 2]
        let expectedPositionBytes: [[UInt8]] = [
            [0xfe, 0xff, 0xff, 0xff], [0xff, 0xff, 0xff, 0xff],
            [0x01, 0x00, 0x00, 0x00], [0x02, 0x00, 0x00, 0x00],
        ]
        let expectedCrcBytes: [[UInt8]] = [[0xb6, 0xee], [0xda, 0x25], [0x1d, 0xf4], [0xaa, 0xe9]]
        let outputs = targets.map { target -> (Int32, [UInt8], [UInt8]) in
            let point = RoutePoint(lat: target / semicirclesPerDegree, lon: 0)
            let bytes = [UInt8](RouteExporter.buildFit(
                route: [point], startTs: startTs, endTs: endTs, sport: "run"
            ))
            let raw = UInt32(bytes[55]) | (UInt32(bytes[56]) << 8)
                | (UInt32(bytes[57]) << 16) | (UInt32(bytes[58]) << 24)
            return (Int32(bitPattern: raw), Array(bytes[55...58]), Array(bytes.suffix(2)))
        }
        XCTAssertEqual(outputs.map(\.0), expected)
        XCTAssertEqual(outputs.map(\.1), expectedPositionBytes)
        XCTAssertEqual(outputs.map(\.2), expectedCrcBytes)
    }

    func testFitWithoutHrDoesNotFabricateHr() {
        // Regression: the FIT "no HR" case must decode to nil HR. validHr accepts 1...300, so a 0xFF
        // sentinel would be misread as a real HR of 255 — the fields must be OMITTED, not sentinelled.
        let data = RouteExporter.render(.fit, route: route, startTs: startTs, endTs: endTs, sport: "walk")
        let a = ActivityFileImporter.parse(data: data, filename: "x.fit").activity
        XCTAssertNotNil(a)
        XCTAssertNil(a!.avgHr)
        XCTAssertNil(a!.maxHr)
        XCTAssertNil(a!.energyKcal)
    }

    /// A pulse per second rides on the route points of the same second and fills the seconds between them
    /// with records of its own, so the importer reads back the whole curve.
    func testFitCarriesTheHeartRateCurve() {
        let times = [startTs, startTs + 600, startTs + 1200, startTs + 1800]
        let pulse = (0...1800).map { ActivityHRSample(ts: startTs + $0, bpm: 120 + $0 % 40) }
        let data = RouteExporter.render(.fit, route: route, startTs: startTs, endTs: endTs, sport: "running",
                                        recordedTimes: times, heartRate: pulse)
        let a = ActivityFileImporter.parse(data: data, filename: "hr.fit").activity
        XCTAssertEqual(a?.route.count, route.count)
        XCTAssertEqual(a?.hrSampleCount, pulse.count)
        XCTAssertEqual(a?.hrSamples.first, pulse.first)
        XCTAssertEqual(a?.hrSamples.last, pulse.last)
        XCTAssertEqual(a?.maxHr, 159)
    }

    /// A workout without a route still makes a usable file: time and pulse records only.
    func testFitWithoutRouteCarriesPulseRecords() {
        let pulse = stride(from: 0, through: 1800, by: 5).map { ActivityHRSample(ts: startTs + $0, bpm: 130) }
        let data = RouteExporter.render(.fit, route: [], startTs: startTs, endTs: endTs,
                                        sport: "Strength Training", heartRate: pulse)
        let a = ActivityFileImporter.parse(data: data, filename: "strength.fit").activity
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.route.count, 0)
        XCTAssertEqual(a?.hrSampleCount, pulse.count)
        XCTAssertEqual(a?.sport, "Strength Training")
        XCTAssertEqual(a.map { Int($0.start.timeIntervalSince1970) }, startTs)
        XCTAssertEqual(a.map { Int($0.end.timeIntervalSince1970) }, endTs)
    }

    /// A pause becomes a timer stop and start, and the pulse sampled inside it stays out of the file.
    func testFitPausesStopTheTimerAndDropTheirPulse() {
        let pulse = (0...1800).map { ActivityHRSample(ts: startTs + $0, bpm: 140) }
        let pause = RouteExporter.Pause(start: startTs + 600, end: startTs + 900)
        let data = RouteExporter.render(.fit, route: [], startTs: startTs, endTs: endTs, sport: "running",
                                        heartRate: pulse, pauses: [pause])
        let a = ActivityFileImporter.parse(data: data, filename: "pause.fit").activity
        XCTAssertEqual(a?.hrSampleCount, pulse.count - 300)
        XCTAssertFalse(a?.hrSamples.contains { $0.ts >= pause.start && $0.ts < pause.end } ?? true)

        let timers = RouteExporter.fitTimeline(times: [], pulse: [:], pauses: [pause], startTs: startTs,
                                               endTs: endTs)
        XCTAssertEqual(timers, [.timer(startTs, running: true), .timer(pause.start, running: false),
                                .timer(pause.end, running: true), .timer(endTs, running: false)])
    }

    func testPausesAreClippedAndMerged() {
        let merged = RouteExporter.mergedPauses(
            [.init(start: 50, end: 120), .init(start: 100, end: 200), .init(start: 900, end: 1500),
             .init(start: 300, end: 300)],
            startTs: 0, endTs: 1000)
        XCTAssertEqual(merged, [.init(start: 50, end: 200), .init(start: 900, end: 1000)])
    }

    /// Sports go out by the FIT profile numbers (hiking is 17, rowing 15) and come back by them.
    func testFitSportsFollowTheProfile() {
        XCTAssertEqual(RouteExporter.fitSportPair("Hiking").sport, 17)
        XCTAssertEqual(RouteExporter.fitSportPair("Rowing").sport, 15)
        XCTAssertEqual(RouteExporter.fitSportPair("Functional strength training").subSport, 20)
        XCTAssertEqual(RouteExporter.fitSportPair("Treadmill run").subSport, 1)
        XCTAssertEqual(RouteExporter.fitSportPair("Something new").sport, 0)
        let expected = ["Hiking": "Hiking", "Rowing": "Rowing", "Yoga": "Yoga", "HIIT": "Cardio",
                        "Walking": "Walking"]
        for (sport, name) in expected {
            let data = RouteExporter.render(.fit, route: route, startTs: startTs, endTs: endTs, sport: sport)
            XCTAssertEqual(ActivityFileImporter.parse(data: data, filename: "s.fit").activity?.sport, name, sport)
        }
    }

    func testInterpolatedTimesSpanTheWindow() {
        let t = RouteExporter.interpolatedTimes(5, 1000, 2000)
        XCTAssertEqual(t.first, 1000)
        XCTAssertEqual(t.last, 2000)
        XCTAssertEqual(t[2], 1500)
        XCTAssertEqual(RouteExporter.interpolatedTimes(1, 500, 900), [500])
    }

    func testIsoMatchesTheKotlinInstantFormat() {
        // Kotlin's Instant.ofEpochSecond(1_723_000_000).toString() == "2024-08-07T03:06:40Z".
        XCTAssertEqual(RouteExporter.iso(1_723_000_000), "2024-08-07T03:06:40Z")
        XCTAssertEqual(RouteExporter.iso(0), "1970-01-01T00:00:00Z")
    }

    func testCanonicalSportCollapsesAliases() {
        XCTAssertEqual(RouteExporter.canonicalSport("Running"), "run")
        XCTAssertEqual(RouteExporter.canonicalSport("bike"), "cycle")
        XCTAssertEqual(RouteExporter.canonicalSport("Walking"), "walk")
        XCTAssertEqual(RouteExporter.canonicalSport(nil), "other")
    }
}
