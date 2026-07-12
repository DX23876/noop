// Tests the OURA_CLOUD_IMPORT-gated Oura import lane; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if OURA_CLOUD_IMPORT
import XCTest
import AuthenticationServices
@testable import Strand

/// A stub AuthProvider that hands out a fixed token and counts refreshes.
private final class StubAuth: AuthProvider {
    var token = "tok-1"
    var validCalls = 0
    var refreshCount = 0
    var isConnected: Bool { true }
    func validAccessToken() async throws -> String { validCalls += 1; return token }
    func refreshedAccessToken() async throws -> String { refreshCount += 1; token = "tok-refreshed"; return token }
    @MainActor func authorize(presentationAnchor: ASPresentationAnchor) async throws {}
    func signOut() {}
}

final class OuraAPIClientTests: XCTestCase {
    override func setUp() { super.setUp(); OuraURLProtocolStub.reset() }

    func testParsePageExtractsDataAndNextToken() throws {
        let json = #"{"data":[{"id":"a"},{"id":"b"}],"next_token":"tok2"}"#.data(using: .utf8)!
        let page = try OuraAPI.parsePage(json)
        XCTAssertEqual(page.data.count, 2)
        XCTAssertEqual(page.nextToken, "tok2")
    }

    func testFetchAllFollowsNextTokenThenStops() async throws {
        OuraURLProtocolStub.queue = [
            .init(status: 200, body: #"{"data":[{"id":"a"}],"next_token":"t2"}"#.data(using: .utf8)!),
            .init(status: 200, body: #"{"data":[{"id":"b"}],"next_token":null}"#.data(using: .utf8)!),
        ]
        let client = OuraAPIClient(auth: StubAuth(), environment: .production,
                                   session: OuraURLProtocolStub.session())
        let rows = try await client.fetchAll(endpoint: "daily_sleep", query: ["start_date": "2026-01-01"])
        XCTAssertEqual(rows.count, 2)
        // Second request carried next_token=t2.
        XCTAssertTrue(OuraURLProtocolStub.requestedURLs.last?.absoluteString.contains("next_token=t2") ?? false)
    }

    func test429IsRetriedAfterBackoff() async throws {
        OuraURLProtocolStub.queue = [
            .init(status: 429, body: Data()),
            .init(status: 200, body: #"{"data":[{"id":"a"}],"next_token":null}"#.data(using: .utf8)!),
        ]
        let client = OuraAPIClient(auth: StubAuth(), environment: .production,
                                   session: OuraURLProtocolStub.session(), backoff: 0)
        let rows = try await client.fetchAll(endpoint: "daily_sleep", query: [:])
        XCTAssertEqual(rows.count, 1)
    }

    func testSandboxBaseURL() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200,
            body: #"{"data":[],"next_token":null}"#.data(using: .utf8)!)]
        let client = OuraAPIClient(auth: StubAuth(), environment: .sandbox,
                                   session: OuraURLProtocolStub.session())
        _ = try await client.fetchAll(endpoint: "personal_info", query: [:])
        XCTAssertTrue(OuraURLProtocolStub.requestedURLs.first?.absoluteString.contains("/v2/sandbox/") ?? false)
    }

    func test401TriggersRefreshThenRetrySucceeds() async throws {
        OuraURLProtocolStub.queue = [
            .init(status: 401, body: Data()),
            .init(status: 200, body: #"{"data":[{"id":"a"}],"next_token":null}"#.data(using: .utf8)!),
        ]
        let stub = StubAuth()
        let client = OuraAPIClient(auth: stub, environment: .production,
                                   session: OuraURLProtocolStub.session())
        let rows = try await client.fetchAll(endpoint: "daily_sleep", query: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(stub.refreshCount, 1)
    }

    func test429ExhaustionThrowsRateLimited() async throws {
        OuraURLProtocolStub.queue = [
            .init(status: 429, body: Data()),
            .init(status: 429, body: Data()),
            .init(status: 429, body: Data()),
        ]
        let client = OuraAPIClient(auth: StubAuth(), environment: .production,
                                   session: OuraURLProtocolStub.session(), backoff: 0)
        do {
            _ = try await client.fetchAll(endpoint: "daily_sleep", query: [:])
            XCTFail("expected rateLimited to be thrown")
        } catch {
            XCTAssertEqual(error as? OuraError, OuraError.rateLimited)
        }
    }
}
#endif // OURA_CLOUD_IMPORT
