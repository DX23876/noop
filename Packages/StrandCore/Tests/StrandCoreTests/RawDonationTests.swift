import XCTest
@testable import StrandCore

/// Donating raw motion. The cases here are the promises the explainer page makes, one test each: nothing
/// records untickedly, the windows stay short, the package carries no identity, nothing is sent without a
/// service, and a donation can be withdrawn by a code the wearer can read out.
final class RawDonationTests: XCTestCase {

    private func settings(_ name: String = UUID().uuidString) -> RawDonationSettings {
        RawDonationSettings(defaults: UserDefaults(suiteName: name)!)
    }

    // MARK: Nothing without a tick

    func testNothingIsPlannedForASportNobodyTicked() {
        let prefs = settings()
        XCTAssertTrue(prefs.sports().isEmpty, "the default must be an empty set, not a full one")
        XCTAssertNil(prefs.plan(for: "Cycling", expected: 3600))
    }

    func testTickingASportIsWhatArmsIt() {
        let prefs = settings()
        prefs.set("Cycling", on: true)
        XCTAssertNotNil(prefs.plan(for: "Cycling", expected: 3600))
        XCTAssertNil(prefs.plan(for: "Running", expected: 3600), "only the ticked sport is armed")
        prefs.set("Cycling", on: false)
        XCTAssertNil(prefs.plan(for: "Cycling", expected: 3600))
    }

    func testTheTickSurvivesTheSpellingTheAppItselfVaries() {
        // `WorkoutSource.sportKey` is the app's own normaliser, and it folds case and spaces. The tick
        // is stored through it so a sport ticked from one screen is still ticked when another screen
        // names it slightly differently.
        let prefs = settings()
        prefs.set("Strength Training", on: true)
        XCTAssertTrue(prefs.isOn("strength training"))
        XCTAssertTrue(prefs.isOn("StrengthTraining"))
        XCTAssertFalse(prefs.isOn("Cycling"))
    }

    // MARK: Short windows, not the whole session

    func testAnHourGetsThreeTwoMinuteWindowsSpreadOut() {
        let windows = RawDonationPlan.windows(expected: 3600)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.map(\.duration), [120, 120, 120])
        XCTAssertGreaterThan(windows[0].startOffset, 0, "the first minute is someone's phone, not sport")
        XCTAssertGreaterThan(windows[1].startOffset, windows[0].endOffset, "the windows must not touch")
        XCTAssertLessThanOrEqual(windows[2].endOffset, 3600)
    }

    func testAShortSessionGetsOneWindowRatherThanThreeOverlappingOnes() {
        let windows = RawDonationPlan.windows(expected: 200)
        XCTAssertEqual(windows.count, 1)
        XCTAssertLessThanOrEqual(windows[0].endOffset, 200)
    }

    func testTheStrapStreamsOnlyInsideAWindow() {
        let windows = RawDonationPlan.windows(expected: 3600)
        XCTAssertFalse(RawDonationPlan.isRecording(at: 0, windows: windows))
        XCTAssertTrue(RawDonationPlan.isRecording(at: windows[0].startOffset + 1, windows: windows))
        XCTAssertFalse(RawDonationPlan.isRecording(at: windows[0].endOffset + 1, windows: windows))
    }

    func testTheWholePlanStaysSmallEnoughToSendOverAPhoneConnection() {
        let bytes = RawDonationPlan.approximateBytes(RawDonationPlan.windows(expected: 3600))
        XCTAssertEqual(bytes, 432_000, "three two-minute windows of 100 Hz six-axis i16")
        XCTAssertLessThan(bytes, 1_000_000, "a donation must not be a megabyte-scale upload")
    }

    func testAThreeHourRideDoesNotBecomeAThreeHourRecording() {
        let long = RawDonationPlan.approximateBytes(RawDonationPlan.windows(expected: 3 * 3600))
        XCTAssertEqual(long, RawDonationPlan.approximateBytes(RawDonationPlan.windows(expected: 3600)),
                       "the plan is three windows however long the session runs")
    }

    // MARK: The package carries no identity

    func testTheMetadataCarriesTheLabelAndTheStrapAndNothingAboutAPerson() {
        let donation = PendingDonation(sport: "Cycling", recordedSeconds: 360, bytes: 432_000,
                                       strapFamily: "whoop4", firmware: "40.1.2",
                                       recordedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let meta = RawDonationPackage.metadata(for: donation, appVersion: "2.1.0")
        XCTAssertEqual(meta["sport"] as? String, "cycling")
        XCTAssertEqual(meta["strap_family"] as? String, "whoop4")
        XCTAssertEqual(meta["sample_rate_hz"] as? Int, 100)
        for forbidden in RawDonationPackage.forbiddenKeys {
            XCTAssertNil(meta[forbidden], "\(forbidden) must never ride along in a donation")
        }
    }

    func testTheRecordingDateIsADayAndNotAMoment() {
        let donation = PendingDonation(sport: "Walking", recordedSeconds: 120, bytes: 1,
                                       strapFamily: "whoop5",
                                       recordedAt: Date(timeIntervalSince1970: 1_800_003_723))
        let day = RawDonationPackage.metadata(for: donation, appVersion: "2.1.0")["recorded_on"] as? String
        XCTAssertEqual(day?.count, 10, "a day, not a timestamp")
        XCTAssertFalse(day?.contains(":") ?? true)
    }

    // MARK: Withdrawal

    func testEveryDonationCarriesAReadableCode() {
        let codes = (0..<50).map { _ in RawDonationCode.make() }
        XCTAssertTrue(codes.allSatisfy(RawDonationCode.isValid))
        XCTAssertTrue(codes.allSatisfy { !$0.contains("0") && !$0.contains("O") && !$0.contains("I") },
                      "the alphabet leaves out what people read wrong over a message")
        XCTAssertGreaterThan(Set(codes).count, 40, "codes must not collide constantly")
    }

    // MARK: Nothing leaves without a service

    func testWithoutAServiceNothingIsUploadedAtAll() async {
        let calls = DonationCounter()
        let uploader = RawDonationUploader(service: nil) { _, _ in
            calls.increment()
            throw ProjectFeedError.unreadable
        }
        let available = await uploader.isAvailable
        XCTAssertFalse(available)
        let outcome = await uploader.send(donation: .init(sport: "Cycling", recordedSeconds: 1, bytes: 1,
                                                          strapFamily: "whoop5"),
                                          payload: Data([1, 2, 3]), metadata: [:])
        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(calls.value, 0)
    }

    func testAnEmptyRecordingIsNeverSent() async {
        let uploader = RawDonationUploader(service: URL(string: "https://relay.test")!) { _, _ in
            XCTFail("an empty payload must not reach the network")
            throw ProjectFeedError.unreadable
        }
        let outcome = await uploader.send(donation: .init(sport: "Cycling", recordedSeconds: 0, bytes: 0,
                                                          strapFamily: "whoop5"),
                                          payload: Data(), metadata: [:])
        XCTAssertEqual(outcome, .refused)
    }

    func testTheUploadAsksForAnAddressAndThenPutsTheBytesThere() async {
        let seen = DonationLog()
        let uploader = RawDonationUploader(service: URL(string: "https://relay.test")!) { request, body in
            seen.append(request.httpMethod ?? "", request.url?.absoluteString ?? "", body?.count ?? 0)
            if request.httpMethod == "POST" {
                let answer = #"{"url":"https://bucket.test/object?signature=x"}"#
                return (Data(answer.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                            headerFields: nil)!)
        }
        let outcome = await uploader.send(donation: .init(sport: "Cycling", recordedSeconds: 360,
                                                          bytes: 9, strapFamily: "whoop5"),
                                          payload: Data(repeating: 7, count: 9),
                                          metadata: ["sport": "cycling"])
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(seen.methods, ["POST", "PUT"], "ask first, then put the bytes straight in")
        XCTAssertTrue(seen.urls[0].hasSuffix("/v1/raw-upload-url"))
        XCTAssertEqual(seen.sizes[1], 9, "the file goes to the bucket, not through the service")
    }

    func testAnAddressThatIsNotHTTPSIsNeverFollowed() async {
        let uploader = RawDonationUploader(service: URL(string: "https://relay.test")!) { request, _ in
            let answer = #"{"url":"http://bucket.test/object"}"#
            return (Data(answer.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                       httpVersion: nil, headerFields: nil)!)
        }
        let outcome = await uploader.send(donation: .init(sport: "Cycling", recordedSeconds: 1, bytes: 1,
                                                          strapFamily: "whoop5"),
                                          payload: Data([1]), metadata: [:])
        XCTAssertEqual(outcome, .unreachable)
    }
}

private final class DonationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class DonationLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var methods: [String] = []
    private(set) var urls: [String] = []
    private(set) var sizes: [Int] = []
    func append(_ method: String, _ url: String, _ size: Int) {
        lock.lock(); methods.append(method); urls.append(url); sizes.append(size); lock.unlock()
    }
}
