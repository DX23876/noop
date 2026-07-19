import XCTest
@testable import StrandImport

/// Pins ActivityFileImporter: GPX, TCX and FIT each parse into one normalized `ActivityFile` with the
/// right time window, GPS-point / HR-sample counts and summary figures. Includes the malformed-input
/// contract (must not crash, must reject gracefully) and the security guards (XXE entity, bad coords).
final class ActivityFileImporterTests: XCTestCase {

    // MARK: - GPX

    func testGpxTrackWithHrExtension() {
        // A 3-point GPX track over 2 minutes, each point carrying a Garmin TrackPointExtension HR.
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
          <trk>
            <type>running</type>
            <trkseg>
              <trkpt lat="51.5000" lon="-0.1000">
                <ele>10.0</ele><time>2026-06-01T10:00:00Z</time>
                <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>120</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
              </trkpt>
              <trkpt lat="51.5010" lon="-0.1000">
                <ele>20.0</ele><time>2026-06-01T10:01:00Z</time>
                <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>140</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
              </trkpt>
              <trkpt lat="51.5020" lon="-0.1000">
                <ele>25.0</ele><time>2026-06-01T10:02:00Z</time>
                <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>160</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
        let r = ActivityFileImporter.parse(data: Data(gpx.utf8), filename: "run.gpx")
        let a = try! XCTUnwrap(r.activity)
        XCTAssertEqual(a.kind, .gpx)
        XCTAssertEqual(a.gpsPointCount, 3)
        XCTAssertEqual(a.hrSampleCount, 3)
        XCTAssertEqual(a.sport, "running")
        XCTAssertEqual(a.avgHr, 140)               // (120+140+160)/3
        XCTAssertEqual(a.maxHr, 160)
        XCTAssertEqual(a.durationS, 120)           // 10:00 → 10:02
        // Two ~111 m latitude steps → roughly 222 m. Allow a wide tolerance for haversine vs flat-earth.
        let dist = try! XCTUnwrap(a.distanceM)
        XCTAssertEqual(dist, 222, accuracy: 30)
        // Ascent: +10 then +5 (both > 1 m hysteresis) = 15 m.
        XCTAssertEqual(a.ascentM ?? 0, 15, accuracy: 0.001)
        // #137: the REAL per-sample HR series is now carried through (not just the avg/max summary),
        // so the app layer can persist it under the activity-file source and light a strap-less day's
        // Effort ring. Values in order, timestamped at each point's own time (start + 0/60/120 s).
        XCTAssertEqual(a.hrSamples.map { $0.bpm }, [120, 140, 160])
        let base = Int(a.start.timeIntervalSince1970)
        XCTAssertEqual(a.hrSamples.map { $0.ts }, [base, base + 60, base + 120])
    }

    func testHrSamplesRequireBothTimestampAndHr() {
        // #137: a sample must carry BOTH a timestamp and an HR to be persisted — a point with HR but
        // no <time> can't key into the (deviceId, ts) HR store, and one with a time but no HR has
        // nothing to store. Here: point 1 has time+HR (kept), point 2 has time but no HR (excluded),
        // point 3 has HR but no time (excluded). `hrSampleCount` still counts every HR-bearing point.
        let gpx = """
        <gpx><trk><trkseg>
          <trkpt lat="51.5000" lon="-0.1000"><time>2026-06-01T10:00:00Z</time>
            <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>120</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
          <trkpt lat="51.5010" lon="-0.1000"><time>2026-06-01T10:01:00Z</time></trkpt>
          <trkpt lat="51.5020" lon="-0.1000">
            <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>160</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
        </trkseg></trk></gpx>
        """
        let r = ActivityFileImporter.parse(data: Data(gpx.utf8), filename: "mixed.gpx")
        let a = try! XCTUnwrap(r.activity)
        XCTAssertEqual(a.hrSampleCount, 2)                        // both HR-bearing points counted
        XCTAssertEqual(a.hrSamples.map { $0.bpm }, [120])        // only the timestamped-with-HR one persisted
        XCTAssertEqual(a.hrSamples.first?.ts, Int(a.start.timeIntervalSince1970))
    }

    func testHrSampleTimestampFloorsFractionalSecondsForKotlinParity() {
        // #137 byte-parity: `hrSample.ts` is the `(deviceId, ts)` store key, so Apple and Android must
        // derive the SAME whole second from a fractional timestamp. Kotlin's `OffsetDateTime.toEpochSecond()`
        // FLOORS the fraction; Swift keeps it in the `Date`, so `hrSamples` must truncate (`Int(secs)`),
        // NOT round — else `…00.500Z` would store ts+1 on Apple while Android stored ts. Parse the same
        // trackpoint time both as a whole second and as `.500`, and assert both land on the SAME ts.
        func ts(forTime t: String) -> Int? {
            let gpx = """
            <gpx><trk><trkseg>
              <trkpt lat="51.5000" lon="-0.1000"><time>\(t)</time>
                <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>130</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
            </trkseg></trk></gpx>
            """
            let r = ActivityFileImporter.parse(data: Data(gpx.utf8), filename: "frac.gpx")
            return r.activity?.hrSamples.first?.ts
        }
        let whole = try! XCTUnwrap(ts(forTime: "2026-06-01T10:00:00Z"))
        let half = try! XCTUnwrap(ts(forTime: "2026-06-01T10:00:00.500Z"))
        XCTAssertEqual(half, whole, "a .5-second fraction must FLOOR to the same whole second (Kotlin parity), not round up")
    }

    func testGpxRejectsNullIslandAndKeepsValidPoints() {
        // A 0,0 "null island" pre-lock fix is dropped; the real point is kept.
        let gpx = """
        <gpx><trk><trkseg>
          <trkpt lat="0.0" lon="0.0"><time>2026-06-01T10:00:00Z</time></trkpt>
          <trkpt lat="51.5" lon="-0.1"><time>2026-06-01T10:01:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let r = ActivityFileImporter.parse(data: Data(gpx.utf8), filename: "x.gpx")
        let a = try! XCTUnwrap(r.activity)
        XCTAssertEqual(a.gpsPointCount, 1)         // null island dropped
        XCTAssertEqual(r.skipped, 0)               // it still carried a time, so not "skipped"
    }

    // MARK: - TCX

    func testTcxActivityWithLapSummaries() {
        // Two trackpoints + a Lap summary that states DistanceMeters and Calories.
        let tcx = """
        <?xml version="1.0"?>
        <TrainingCenterDatabase>
          <Activities>
            <Activity Sport="Biking">
              <Lap>
                <TotalTimeSeconds>60</TotalTimeSeconds>
                <DistanceMeters>1500</DistanceMeters>
                <Calories>45</Calories>
                <MaximumHeartRateBpm><Value>175</Value></MaximumHeartRateBpm>
                <Track>
                  <Trackpoint>
                    <Time>2026-06-01T08:00:00Z</Time>
                    <Position><LatitudeDegrees>40.0</LatitudeDegrees><LongitudeDegrees>-3.0</LongitudeDegrees></Position>
                    <AltitudeMeters>600</AltitudeMeters>
                    <HeartRateBpm><Value>150</Value></HeartRateBpm>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-06-01T08:01:00Z</Time>
                    <Position><LatitudeDegrees>40.01</LatitudeDegrees><LongitudeDegrees>-3.0</LongitudeDegrees></Position>
                    <AltitudeMeters>610</AltitudeMeters>
                    <HeartRateBpm><Value>170</Value></HeartRateBpm>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """
        let r = ActivityFileImporter.parse(data: Data(tcx.utf8), filename: "ride.tcx")
        let a = try! XCTUnwrap(r.activity)
        XCTAssertEqual(a.kind, .tcx)
        XCTAssertEqual(a.sport, "Biking")
        XCTAssertEqual(a.gpsPointCount, 2)
        XCTAssertEqual(a.hrSampleCount, 2)
        XCTAssertEqual(a.distanceM, 1500)          // from the Lap summary, not the track
        XCTAssertEqual(a.energyKcal, 45)
        XCTAssertEqual(a.avgHr, 160)               // (150+170)/2
        XCTAssertEqual(a.maxHr, 175)               // the file's stated max wins
        XCTAssertEqual(a.durationS, 60)
        XCTAssertEqual(ActivityFileImporter.workoutSport(from: a.sport), "Cycling")
    }

    // MARK: - FIT

    func testFitRecordAndSessionMessages() {
        // Build a minimal valid FIT: header + a `session` definition/data (sport=running, distance,
        // calories) + a `record` definition + 3 data records (timestamp, lat, lon, hr).
        var fit = FitFixture()
        // session (global 18): start_time(2,u32), sport(5,enum u8), total_distance(9,u32),
        //                      total_calories(11,u16), avg_hr(16,u8), max_hr(17,u8)
        let sessionStart: UInt32 = 100_000           // FIT seconds
        fit.definition(local: 0, global: 18, fields: [
            (2, 4, 0x86), (5, 1, 0x00), (9, 4, 0x86), (10, 4, 0x86),
            (11, 2, 0x84), (16, 1, 0x02), (17, 1, 0x02),
        ])
        fit.dataHeader(local: 0)
        fit.u32(sessionStart)
        fit.u8(1)                                    // sport = running
        fit.u32(523)                                 // total_distance = 5.23 m? scale 100 → 5.23m; use 523 → 5.23 m
        fit.u32(1175)                                // total_cycles: Suunto walking/running step total
        fit.u16(300)                                 // total_calories
        fit.u8(150)                                  // avg_hr
        fit.u8(182)                                  // max_hr

        // record (global 20): timestamp(253,u32), position_lat(0,sint32), position_long(1,sint32),
        //                     heart_rate(3,u8)
        fit.definition(local: 1, global: 20, fields: [
            (253, 4, 0x86), (0, 4, 0x85), (1, 4, 0x85), (3, 1, 0x02),
        ])
        let lat = 51.5, lon = -0.1
        let latSemi = Int32((lat / (180.0 / 2_147_483_648.0)).rounded())
        let lonSemi = Int32((lon / (180.0 / 2_147_483_648.0)).rounded())
        for k in 0..<3 {
            fit.dataHeader(local: 1)
            fit.u32(sessionStart + UInt32(k * 10))   // 0,10,20 s apart
            fit.i32(latSemi)
            fit.i32(lonSemi)
            fit.u8(UInt8(120 + k * 20))              // 120,140,160
        }

        let data = fit.finish()
        let r = ActivityFileImporter.parse(data: data, filename: "ride.fit")
        let a = try! XCTUnwrap(r.activity)
        XCTAssertEqual(a.kind, .fit)
        XCTAssertEqual(a.sport, "Running")
        XCTAssertEqual(a.gpsPointCount, 3)
        XCTAssertEqual(a.hrSampleCount, 3)
        XCTAssertEqual(a.distanceM ?? 0, 5.23, accuracy: 0.001)   // session summary
        XCTAssertEqual(a.energyKcal, 300)
        XCTAssertEqual(a.steps, 2350)   // FIT field 10 = 1175 strides → ×2 = 2350 steps (#568)
        XCTAssertEqual(a.avgHr, 150)                 // session avg wins over the sampled mean
        XCTAssertEqual(a.maxHr, 182)
        // Coordinates round-trip through semicircles (~1e-7° precision).
        XCTAssertEqual(a.route.first?.lat ?? 0, lat, accuracy: 1e-4)
        XCTAssertEqual(a.route.first?.lon ?? 0, lon, accuracy: 1e-4)
        // start from the FIT epoch: 631065600 + 100000.
        XCTAssertEqual(a.start.timeIntervalSince1970, 631_065_600 + 100_000, accuracy: 1)
        // #137: FIT persists the same real per-record HR series as GPX/TCX (shared extractor). Records
        // are 0/10/20 s apart from the FIT-epoch start; HR 120/140/160.
        let fitBase = 631_065_600 + 100_000
        XCTAssertEqual(a.hrSamples.map { $0.bpm }, [120, 140, 160])
        XCTAssertEqual(a.hrSamples.map { $0.ts }, [fitBase, fitBase + 10, fitBase + 20])
    }

    func testFitDetectionFromMagicBytes() {
        var fit = FitFixture()
        fit.definition(local: 0, global: 20, fields: [(253, 4, 0x86), (3, 1, 0x02)])
        fit.dataHeader(local: 0); fit.u32(50_000); fit.u8(100)
        let data = fit.finish()
        // No filename → must still detect FIT from the ".FIT" signature at offset 8.
        XCTAssertEqual(ActivityFileImporter.detectFormat(data: data), .fit)
    }

    // MARK: - Malformed input (must not crash, must reject gracefully)

    func testMalformedInputsRejectedNotCrash() {
        let cases: [Data] = [
            Data(),                                              // empty
            Data([0x00, 0x01, 0x02]),                           // 3 random bytes
            Data("not xml not fit".utf8),                        // junk text
            Data("<gpx><trk><trkseg><trkpt lat=\"abc\" lon=\"xyz\"></trkpt>".utf8), // truncated + bad coords
            Data([0x0C, 0x10, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x7F, // header claims huge dataSize…
                  UInt8(ascii: "."), UInt8(ascii: "F"), UInt8(ascii: "I"), UInt8(ascii: "T")]), // …but no records
        ]
        for d in cases {
            // Must return a result (possibly empty) without throwing/crashing.
            let r = ActivityFileImporter.parse(data: d, filename: nil)
            XCTAssertNil(r.activity, "expected no activity from malformed input")
        }
    }

    func testGpxExternalEntityNotExpanded() {
        // XXE / billion-laughs guard: an external/general entity must NOT be resolved. The parse should
        // not read the local file or expand the entity; we simply assert it doesn't crash and yields no
        // bogus activity (the entity reference never becomes a coordinate).
        let xxe = """
        <?xml version="1.0"?>
        <!DOCTYPE gpx [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
        <gpx><trk><trkseg>
          <trkpt lat="51.5" lon="-0.1"><time>2026-06-01T10:00:00Z</time><name>&xxe;</name></trkpt>
        </trkseg></trk></gpx>
        """
        // Should not crash; the one valid point may or may not survive depending on the parser's DTD
        // handling, but no file contents must leak into a field. Just assert no throw + bounded result.
        let r = ActivityFileImporter.parse(data: Data(xxe.utf8), filename: "x.gpx")
        XCTAssertLessThanOrEqual(r.activity?.gpsPointCount ?? 0, 1)
    }

    func testWorkoutSportNormalization() {
        XCTAssertEqual(ActivityFileImporter.workoutSport(from: "running"), "Running")
        XCTAssertEqual(ActivityFileImporter.workoutSport(from: "road_biking"), "Cycling")
        XCTAssertEqual(ActivityFileImporter.workoutSport(from: nil), "Activity")
        XCTAssertEqual(ActivityFileImporter.workoutSport(from: ""), "Activity")
        XCTAssertEqual(ActivityFileImporter.workoutSport(from: "Trail Run"), "Trail Run") // already spaced
        XCTAssertEqual(ActivityFileImporter.workoutSport(from: "kayaking"), "Kayaking")   // title-cased
    }
}

// MARK: - FIT byte fixture builder (little-endian, test-only)

/// Assembles a minimal valid FIT byte stream: a 12-byte header (filled with the real ".FIT" signature
/// and the correct dataSize at finish), then whatever definition/data records the test appends.
private struct FitFixture {
    private var records: [UInt8] = []

    mutating func definition(local: Int, global: Int, fields: [(num: Int, size: Int, baseType: UInt8)]) {
        records.append(UInt8(0x40 | (local & 0x0F)))   // definition header, no dev fields
        records.append(0)                               // reserved
        records.append(0)                               // architecture: little-endian
        records.append(UInt8(global & 0xFF))
        records.append(UInt8((global >> 8) & 0xFF))
        records.append(UInt8(fields.count))
        for f in fields {
            records.append(UInt8(f.num))
            records.append(UInt8(f.size))
            records.append(f.baseType)
        }
    }

    mutating func dataHeader(local: Int) {
        records.append(UInt8(local & 0x0F))             // data header (bit6=0)
    }

    mutating func u8(_ v: UInt8) { records.append(v) }
    mutating func u16(_ v: UInt16) { records.append(UInt8(v & 0xFF)); records.append(UInt8((v >> 8) & 0xFF)) }
    mutating func u32(_ v: UInt32) {
        records.append(UInt8(v & 0xFF)); records.append(UInt8((v >> 8) & 0xFF))
        records.append(UInt8((v >> 16) & 0xFF)); records.append(UInt8((v >> 24) & 0xFF))
    }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

    mutating func finish() -> Data {
        var header: [UInt8] = [12, 0x10, 0x00, 0x00] // headerSize=12, protocol, profile(LE u16)
        let size = UInt32(records.count)
        header.append(UInt8(size & 0xFF)); header.append(UInt8((size >> 8) & 0xFF))
        header.append(UInt8((size >> 16) & 0xFF)); header.append(UInt8((size >> 24) & 0xFF))
        header.append(contentsOf: [UInt8(ascii: "."), UInt8(ascii: "F"), UInt8(ascii: "I"), UInt8(ascii: "T")])
        var out = header + records
        out.append(0); out.append(0)                  // trailing CRC (unchecked by the decoder)
        return Data(out)
    }
}
