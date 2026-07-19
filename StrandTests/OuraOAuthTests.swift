// Tests the OURA_CLOUD_IMPORT-gated Oura import lane; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if OURA_CLOUD_IMPORT
import XCTest
@testable import Strand

final class OuraOAuthTests: XCTestCase {
    private let creds = OuraCredentials(clientId: "cid", clientSecret: "sec",
                                        redirectURI: "noop://oura/callback")

    func testAuthorizeURLHasRequiredParams() throws {
        let url = OuraOAuth.authorizeURL(credentials: creds, state: "xyz")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "cloud.ouraring.com")
        XCTAssertEqual(comps.path, "/oauth/authorize")
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["client_id"], "cid")
        XCTAssertEqual(q["redirect_uri"], "noop://oura/callback")
        XCTAssertEqual(q["state"], "xyz")
        XCTAssertEqual(q["scope"], OuraOAuth.scopes.joined(separator: " "))
        XCTAssertTrue(OuraOAuth.scopes.contains("daily"))
        XCTAssertTrue(OuraOAuth.scopes.contains("heartrate"))
        XCTAssertTrue(OuraOAuth.scopes.contains("spo2"))
        XCTAssertFalse(OuraOAuth.scopes.contains("spo2Daily"))
    }

    func testTokenExchangeRequestIsFormPost() throws {
        let req = OuraOAuth.tokenExchangeRequest(credentials: creds, code: "the-code")
        XCTAssertEqual(req.url?.absoluteString, "https://api.ouraring.com/oauth/token")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=the-code"))
        XCTAssertTrue(body.contains("client_id=cid"))
        XCTAssertTrue(body.contains("client_secret=sec"))
    }

    func testParseTokenResponseComputesExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = #"{"access_token":"acc","refresh_token":"ref","expires_in":86400}"#.data(using: .utf8)!
        let tokens = try OuraOAuth.parseTokenResponse(json, now: now)
        XCTAssertEqual(tokens.accessToken, "acc")
        XCTAssertEqual(tokens.refreshToken, "ref")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(86400))
    }

    func testParseTokenResponseDefaultsExpiryWhenExpiresInAbsent() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = #"{"access_token":"acc"}"#.data(using: .utf8)!
        let tokens = try OuraOAuth.parseTokenResponse(json, now: now)
        XCTAssertEqual(tokens.accessToken, "acc")
        XCTAssertNil(tokens.refreshToken)
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(2_592_000))
    }

    func testParseTokenResponseThrowsOnMissingAccessToken() {
        let json = #"{"error":"invalid_grant"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try OuraOAuth.parseTokenResponse(json, now: Date()))
    }

    func testTokenExchangeRequestEscapesReservedCharsInSecret() {
        let c = OuraCredentials(clientId: "cid", clientSecret: "aB+cd/eF12==", redirectURI: "noop://oura/callback")
        let req = OuraOAuth.tokenExchangeRequest(credentials: c, code: "x+y")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("client_secret=aB%2Bcd%2FeF12%3D%3D"))   // + -> %2B, / -> %2F, = -> %3D
        XCTAssertTrue(body.contains("code=x%2By"))                            // + escaped, not left literal
        XCTAssertFalse(body.contains("aB+cd"))                                // no raw '+'
    }
}
#endif // OURA_CLOUD_IMPORT
