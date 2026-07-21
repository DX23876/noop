import XCTest
@testable import Strand

/// What a failure OFFERS the user, not just what it says.
///
/// Every network failure used to become `AICoachError.network(localizedDescription)` and land in the
/// chat as raw CFNetwork prose under a single Retry — including "you have no connection", where an
/// immediate retry cannot possibly work, and "your key was rejected", where retrying the same key fails
/// identically. The recovery is derived from the TYPED error rather than the message, because matching
/// on a localized sentence works in English and nowhere else.
@MainActor
final class CoachErrorRecoveryTests: XCTestCase {

    // MARK: - Offline is its own case

    func testNoConnectionMapsToOffline() {
        for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed] {
            let mapped = coachTransportError(URLError(code))
            XCTAssertEqual(mapped.recovery, .retry(after: nil))
            XCTAssertTrue(mapped.errorDescription?.contains("offline") ?? false,
                          "\(code): CFNetwork prose is not an explanation. Got: "
                          + (mapped.errorDescription ?? "nil"))
        }
    }

    /// The message says the rest of the app is fine — an offline user should not think NOOP is broken,
    /// since the coach is the only feature that needs a connection at all.
    func testOfflineMessageSaysTheRestOfTheAppStillWorks() {
        XCTAssertTrue(AICoachError.offline.errorDescription?.contains("keeps working") ?? false)
    }

    func testAnUnrelatedURLErrorIsNotClaimedToBeOffline() {
        let mapped = coachTransportError(URLError(.badServerResponse))
        guard case .network = mapped else {
            return XCTFail("a server-side failure must not be reported as the user's connection")
        }
    }

    func testNonURLErrorsStillCarryTheirDescription() {
        struct Odd: Error, LocalizedError { var errorDescription: String? { "something odd" } }
        guard case .network(let detail) = coachTransportError(Odd()) else {
            return XCTFail("expected a network error")
        }
        XCTAssertTrue(detail.contains("something odd"))
    }

    // MARK: - Recovery per failure

    func testRejectedKeySendsTheUserToTheKeyScreen() {
        XCTAssertEqual(AICoachError.badKey.recovery, .reauthenticate,
                       "retrying a rejected key fails identically — the way out is a new key")
    }

    func testRateLimitCarriesTheProvidersOwnWait() {
        XCTAssertEqual(AICoachError.rateLimited(retryAfter: 30).recovery, .retry(after: 30))
        XCTAssertEqual(AICoachError.rateLimited(retryAfter: nil).recovery, .retry(after: nil))
    }

    func testRateLimitMessageNamesTheWaitWhenKnown() {
        XCTAssertTrue(AICoachError.rateLimited(retryAfter: 30).errorDescription?.contains("30") ?? false)
    }

    func testServerFailuresRetryOnlyWhenRetryingCouldHelp() {
        XCTAssertEqual(AICoachError.server(503, "").recovery, .retry(after: nil),
                       "5xx is the provider's problem and usually transient")
        XCTAssertEqual(AICoachError.server(400, "bad request").recovery, .none,
                       "a 4xx repeated unchanged fails the same way — offering Retry is a lie")
    }

    func testSetupProblemsOfferNoRetryAtAll() {
        XCTAssertEqual(AICoachError.noKey.recovery, .none)
        XCTAssertEqual(AICoachError.noModel.recovery, .none)
        XCTAssertEqual(AICoachError.emptyQuestion.recovery, .none)
    }

    // MARK: - Retry-After parsing

    private func response(retryAfter: String?) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 429,
                        httpVersion: nil,
                        headerFields: retryAfter.map { ["Retry-After": $0] })!
    }

    func testRetryAfterAsPlainSeconds() {
        XCTAssertEqual(retryAfterSeconds(response(retryAfter: "30")), 30)
    }

    func testRetryAfterAsHTTPDate() {
        let future = Date().addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let parsed = retryAfterSeconds(response(retryAfter: formatter.string(from: future)))
        XCTAssertNotNil(parsed, "the header is a delay OR a date; both are legal")
        XCTAssertEqual(Double(parsed ?? 0), 120, accuracy: 2)
    }

    func testPastDateDoesNotProduceANegativeCountdown() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let past = formatter.string(from: Date().addingTimeInterval(-500))

        XCTAssertNil(retryAfterSeconds(response(retryAfter: past)),
                     "a countdown must never start negative")
    }

    func testMissingOrUnparseableHeaderIsNil() {
        XCTAssertNil(retryAfterSeconds(response(retryAfter: nil)))
        XCTAssertNil(retryAfterSeconds(response(retryAfter: "soon")))
        XCTAssertNil(retryAfterSeconds(response(retryAfter: "0")), "zero is no wait, not a countdown")
    }

    // MARK: - Engine plumbing

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-error-\(UUID().uuidString)"))
    }

    func testSetErrorRecordsBothTheMessageAndTheType() {
        let engine = makeEngine()
        engine.setError(URLError(.notConnectedToInternet))

        XCTAssertEqual(engine.lastError, .offline)
        XCTAssertEqual(engine.errorText, AICoachError.offline.errorDescription)
    }

    func testSetErrorKeepsAnAlreadyTypedCoachError() {
        let engine = makeEngine()
        engine.setError(AICoachError.badKey)
        XCTAssertEqual(engine.lastError, .badKey, "must not be re-classified as a transport failure")
    }

    func testClearingClearsBothHalves() {
        let engine = makeEngine()
        engine.setError(AICoachError.badKey)
        engine.clearError()

        XCTAssertNil(engine.errorText)
        XCTAssertNil(engine.lastError,
                     "a stale typed error would leave a Retry under a chat that has since succeeded")
    }
}

