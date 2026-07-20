import XCTest
import WhoopStore
@testable import Strand

/// PR #581 — the HealthKit-free Shortcuts IMPORT (`noop://import-health`). Pins the URL/base64 decode,
/// the line parse, and — the review's central concern — LOOP-FREEDOM: an imported value must land under
/// the `apple-health` source, never the strap, so the #155 export (which reads the strap only) can never
/// re-emit it and create an export→import→export cycle.
final class ShortcutHealthImportTests: XCTestCase {

    private func url(payloadText: String, version: Int? = 1, host: String = "import-health",
                     scheme: String = "noop") -> URL {
        let b64 = Data(payloadText.utf8).base64EncodedString()
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        var items = [URLQueryItem(name: "payload", value: b64)]
        if let version { items.append(URLQueryItem(name: "v", value: String(version))) }
        c.queryItems = items
        return c.url!
    }

    // MARK: - URL decode + guards

    func testDecodesValidPayload() {
        let u = url(payloadText: "D,2026-06-01,1000,,,,,,,")
        guard case .success(let text) = ShortcutHealthImport.decodePayload(from: u) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(text, "D,2026-06-01,1000,,,,,,,")
    }

    func testPrepareStagesWithoutWriting() {
        let u = url(payloadText: "D,2026-06-01,1000,,,,,,,\nW,1000,1600,Walking,,,")
        guard case .success(let pending) = ShortcutHealthImport.prepare(url: u) else {
            return XCTFail("expected pending import")
        }
        XCTAssertEqual(pending.daysCount, 1)
        XCTAssertEqual(pending.workoutsCount, 1)
    }

    func testRejectsForeignScheme() {
        let u = url(payloadText: "D,2026-06-01,1000", scheme: "https")
        guard case .failure = ShortcutHealthImport.decodePayload(from: u) else {
            return XCTFail("a non-noop scheme must be rejected")
        }
    }

    func testRejectsWrongHost() {
        let u = url(payloadText: "D,2026-06-01,1000", host: "import-strap")
        guard case .failure = ShortcutHealthImport.decodePayload(from: u) else {
            return XCTFail("an unknown host must be rejected")
        }
    }

    func testRejectsUnsupportedVersion() {
        let u = url(payloadText: "D,2026-06-01,1000", version: 99)
        guard case .failure = ShortcutHealthImport.decodePayload(from: u) else {
            return XCTFail("a future version must be rejected")
        }
    }

    func testRejectsOversizedPayloadBeforeImport() {
        let huge = String(repeating: "A", count: ShortcutHealthImport.maxPayloadBytes + 1)
        let u = url(payloadText: huge)
        guard case .failure = ShortcutHealthImport.decodePayload(from: u) else {
            return XCTFail("an oversized payload must be rejected")
        }
    }

    func testAcceptsURLSafeBase64WithoutPadding() {
        // "??" forces a base64 byte that differs between standard (+/) and URL-safe (-_) alphabets.
        let text = "D,2026-06-01,1000,12.5,,,,,"
        let standard = Data(text.utf8).base64EncodedString()
        let urlSafe = standard.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(ShortcutHealthImport.decodeBase64(urlSafe), Data(text.utf8))
    }

    // MARK: - Parse

    func testParsesDayAllFields() {
        let p = ShortcutHealthImport.parse("D,2026-06-01,8000,420.5,52,68.2,61,455,48.1,80.4")
        XCTAssertEqual(p.days.count, 1)
        let d = p.days[0]
        XCTAssertEqual(d.day, "2026-06-01")
        XCTAssertEqual(d.steps, 8000)
        XCTAssertEqual(d.activeKcal, 420.5)
        XCTAssertEqual(d.restingHr, 52)
        XCTAssertEqual(d.hrvMs, 68.2)
        XCTAssertEqual(d.avgHr, 61)
        XCTAssertEqual(d.asleepMin, 455)
        XCTAssertEqual(d.vo2max, 48.1)
        XCTAssertEqual(d.weightKg, 80.4)
    }

    func testEmptyFieldsStayNil() {
        let p = ShortcutHealthImport.parse("D,2026-06-01,,,52,,,,,")
        XCTAssertEqual(p.days.count, 1)
        XCTAssertNil(p.days[0].steps)
        XCTAssertEqual(p.days[0].restingHr, 52)
        XCTAssertNil(p.days[0].weightKg)
    }

    func testDayWithNoMetricIsDropped() {
        XCTAssertTrue(ShortcutHealthImport.parse("D,2026-06-01,,,,,,,,").days.isEmpty)
    }

    func testInvalidDayKeyRejected() {
        XCTAssertTrue(ShortcutHealthImport.parse("D,June 1st,8000").days.isEmpty)
        XCTAssertFalse(ShortcutHealthImport.isValidDay("2026-6-1"))
        XCTAssertTrue(ShortcutHealthImport.isValidDay("2026-06-01"))
    }

    func testParsesWorkout() {
        let p = ShortcutHealthImport.parse("W,1000,2800,Running,1800,250.0,5200")
        XCTAssertEqual(p.workouts.count, 1)
        let w = p.workouts[0]
        XCTAssertEqual(w.startTs, 1000)
        XCTAssertEqual(w.endTs, 2800)
        XCTAssertEqual(w.sport, "Running")
        XCTAssertEqual(w.durationS, 1800)
        XCTAssertEqual(w.energyKcal, 250.0)
        XCTAssertEqual(w.distanceM, 5200)
    }

    func testWorkoutDurationDefaultsToSpan() {
        let p = ShortcutHealthImport.parse("W,1000,2800,Walking,,,")
        XCTAssertEqual(p.workouts.first?.durationS, 1800)   // end - start
    }

    func testUnknownRecordKindIgnored() {
        let p = ShortcutHealthImport.parse("X,foo,bar\nD,2026-06-01,8000")
        XCTAssertEqual(p.days.count, 1)
        XCTAssertTrue(p.workouts.isEmpty)
    }

    func testMixedRecordsAndBlankLines() {
        let p = ShortcutHealthImport.parse("""
        D,2026-06-01,8000,,,,,,
        \r
        W,1000,2800,Cycling,,,

        D,2026-06-02,9000,,,,,,
        """)
        XCTAssertEqual(p.days.count, 2)
        XCTAssertEqual(p.workouts.count, 1)
    }

    // MARK: - Loop-freedom (the #581 review's central concern)

    func testRejectsStrapTarget() async throws {
        let store = try await WhoopStore.inMemory()
        for strap in ShortcutHealthImport.forbiddenSources {
            let outcome = await ShortcutHealthImport.ingest(
                url: url(payloadText: "D,2026-06-01,8000,,,,,,"), into: store, targetSource: strap)
            XCTAssertEqual(outcome, .rejected("Import target must be the Apple Health source, not the strap."),
                           "ingesting into \(strap) must be rejected so the export can't re-emit it")
        }
    }

    func testIngestWritesOnlyToAppleSourceNotStrap() async throws {
        let store = try await WhoopStore.inMemory()
        let u = url(payloadText: "D,2026-06-01,8000,420.5,52,,,,\nW,1000,2800,Running,1800,250,5200")
        let outcome = await ShortcutHealthImport.ingest(url: u, into: store)
        XCTAssertEqual(outcome, .imported(days: 1, workouts: 1))

        // The data is under apple-health…
        let appleDays = try await store.appleDaily(deviceId: "apple-health", from: "0000", to: "9999")
        XCTAssertEqual(appleDays.count, 1)
        XCTAssertEqual(appleDays.first?.steps, 8000)
        let appleWorkouts = try await store.workouts(deviceId: "apple-health", from: 0, to: 9_999_999, limit: 100)
        XCTAssertEqual(appleWorkouts.count, 1)

        // …and NOTHING leaked onto the strap source (the loop-freedom invariant).
        for strap in ShortcutHealthImport.forbiddenSources {
            let strapDays = try await store.appleDaily(deviceId: strap, from: "0000", to: "9999")
            XCTAssertTrue(strapDays.isEmpty, "no Apple-daily row may land on \(strap)")
            let strapWorkouts = try await store.workouts(deviceId: strap, from: 0, to: 9_999_999, limit: 100)
            XCTAssertTrue(strapWorkouts.isEmpty, "no workout may land on \(strap)")
            let strapMetrics = try await store.dailyMetrics(deviceId: strap, from: "0000", to: "9999")
            XCTAssertTrue(strapMetrics.isEmpty, "no daily-metric row may land on \(strap)")
        }
    }

    func testEmptyPayloadIsNothingToImport() async throws {
        let store = try await WhoopStore.inMemory()
        let outcome = await ShortcutHealthImport.ingest(url: url(payloadText: "X,junk\n\n"), into: store)
        XCTAssertEqual(outcome, .nothingToImport)
    }

    func testTargetSourceIsTheAppleSource() {
        XCTAssertEqual(ShortcutHealthImport.targetSource, WorkoutSource.appleHealthSource)
        XCTAssertFalse(ShortcutHealthImport.forbiddenSources.contains(ShortcutHealthImport.targetSource))
    }
}
