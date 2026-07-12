# Oura Live API Import — Plan 2: Network + Auth (app target)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the app-target network + auth layer for the Oura cloud import — Keychain token storage, credentials, the OAuth2 authorization-code flow (bring-your-own Oura app), and the paging/backoff `URLSession` API client — behind an `AuthProvider` seam, all in `Strand/Oura/`.

**Architecture:** Networking lives in the **app target** (`Strand/`), beside `Strand/AI/AICoach.swift` — never in a package (the packages stay network-free; that's the privacy invariant Plan 1 preserved). We mirror three proven app-target patterns: `AIKeyStore` (Keychain), `AICoachError` (`LocalizedError`), and the injected `session: URLSession = .shared` seam with **pure parse/build helpers split out** so the request-building, response-envelope parsing, paging, and token math are unit-tested without a live socket. The interactive `ASWebAuthenticationSession` step is thin, behind `AuthProvider`, and integration-verified (it opens a browser — not headless-unit-testable).

**Tech stack:** Swift 6.3.1 (app builds via XcodeGen `Strand.xcodeproj`), `Foundation` + `Security` (Keychain) + `AuthenticationServices` (`ASWebAuthenticationSession`, new to this repo). XCTest in `StrandTests`. Tests run via `xcodebuild`, NOT `swift test` (this is the Xcode app target, not an SPM package).

## Global Constraints

Every task implicitly includes these:
- **Networking only in the app target.** These files live in `Strand/Oura/`. No package gains a `URLSession`/`URLRequest`/`ASWebAuthenticationSession` import. `Strand/` sources are auto-globbed into both the `Strand` (macOS) and `NOOPiOS` targets by `project.yml` — no manifest edit needed for new `.swift` files (but the project must be regenerated: `xcodegen generate`).
- **Second opt-in network lane.** This is off-by-default and user-initiated (the AI Coach is the first exception). Data flow is inbound (Oura → device, under the user's own OAuth grant). No NOOP server. Tokens live only in the Keychain, never UserDefaults/plist/logs.
- **BYO Oura app, no PKCE.** OAuth2 authorization-code against Oura: authorize `https://cloud.ouraring.com/oauth/authorize`, token `https://api.ouraring.com/oauth/token`, bearer header `Authorization: Bearer <token>`. `client_id`+`client_secret` come from an untracked xcconfig via Info.plist (Task 5). Scopes (all 8): `email personal daily heartrate workout tag session spo2Daily`.
- **Testability seam.** Every networked type takes `session: URLSession = .shared` in its initializer (mirroring `AICoachEngine`), so tests inject a `URLSession` backed by a `URLProtocol` stub. Pure builders/parsers are `static` and separately unit-tested (mirroring `AnthropicClient.parseModels`).
- **Provenance / consumes Plan 1.** This plan does not write to the store yet (that's Plan 3). It produces the fetched raw JSON pages + tokens that Plan 3's writer consumes. `deviceId = "oura-api"` is the partition (Plan 3).
- **Build/test path.** `xcodegen generate` then `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/<Class> CODE_SIGNING_ALLOWED=NO`. The first build is a full app compile (minutes); subsequent task builds are incremental. The full macOS app compiling clean under this toolchain is confirmed.

---

### Task 1: `OuraError` + `OuraTokenStore` (Keychain)

The typed error surface and secure token storage, mirroring `AICoachError` / `AIKeyStore`.

**Files:**
- Create: `Strand/Oura/OuraError.swift`
- Create: `Strand/Oura/OuraTokenStore.swift`
- Test: `StrandTests/OuraTokenStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum OuraError: LocalizedError { case notConnected, authFailed(String), badResponse(Int, String), rateLimited, network(String), decode, tokenExchangeFailed(String) }`
  - `struct OuraTokens: Equatable { let accessToken: String; let refreshToken: String?; let expiresAt: Date }` with `var isExpired: Bool` (true within a 60 s skew of `expiresAt`).
  - `enum OuraTokenStore` with `static func save(_ tokens: OuraTokens) -> Bool`, `static func load() -> OuraTokens?`, `static func clear()`, `static var isConnected: Bool`.

- [ ] **Step 1: Write the failing test**

Create `StrandTests/OuraTokenStoreTests.swift`:

```swift
import XCTest
@testable import Strand

final class OuraTokenStoreTests: XCTestCase {
    override func setUp() { super.setUp(); OuraTokenStore.clear() }
    override func tearDown() { OuraTokenStore.clear(); super.tearDown() }

    func testSaveLoadClearRoundTrip() {
        XCTAssertFalse(OuraTokenStore.isConnected)
        XCTAssertNil(OuraTokenStore.load())

        let exp = Date(timeIntervalSince1970: 2_000_000_000)
        let t = OuraTokens(accessToken: "acc", refreshToken: "ref", expiresAt: exp)
        XCTAssertTrue(OuraTokenStore.save(t))
        XCTAssertTrue(OuraTokenStore.isConnected)

        let loaded = OuraTokenStore.load()
        XCTAssertEqual(loaded, t)

        OuraTokenStore.clear()
        XCTAssertNil(OuraTokenStore.load())
        XCTAssertFalse(OuraTokenStore.isConnected)
    }

    func testExpiryUsesSkew() {
        let almostNow = OuraTokens(accessToken: "a", refreshToken: nil,
                                   expiresAt: Date(timeIntervalSinceNow: 30))   // <60 s away
        XCTAssertTrue(almostNow.isExpired)
        let later = OuraTokens(accessToken: "a", refreshToken: nil,
                               expiresAt: Date(timeIntervalSinceNow: 600))
        XCTAssertFalse(later.isExpired)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraTokenStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: FAIL — `OuraTokenStore` / `OuraTokens` / `OuraError` undefined (compile error).

- [ ] **Step 3: Implement `OuraError`**

Create `Strand/Oura/OuraError.swift`:

```swift
import Foundation

/// User-facing failure reasons for the Oura cloud-import lane, mapped to clear, non-crashing messages.
/// Mirrors AICoachError's shape (LocalizedError + errorDescription).
enum OuraError: LocalizedError, Equatable {
    case notConnected
    case authFailed(String)
    case tokenExchangeFailed(String)
    case badResponse(Int, String)
    case rateLimited
    case network(String)
    case decode

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect your Oura account first."
        case .authFailed(let d):
            return "Oura sign-in didn't complete: \(d)"
        case .tokenExchangeFailed(let d):
            return "Couldn't exchange the Oura authorization code: \(d)"
        case .badResponse(let code, let detail):
            let extra = detail.isEmpty ? "" : " — \(detail)"
            return "Oura returned an error (\(code))\(extra)."
        case .rateLimited:
            return "Oura is rate-limiting requests. Waiting before retrying."
        case .network(let d):
            return "Network problem talking to Oura: \(d)"
        case .decode:
            return "Couldn't read Oura's response."
        }
    }
}
```

- [ ] **Step 4: Implement `OuraTokens` + `OuraTokenStore`**

Create `Strand/Oura/OuraTokenStore.swift`:

```swift
import Foundation
import Security

/// The OAuth tokens for the Oura cloud lane. `expiresAt` is absolute (computed from `expires_in` at
/// exchange time). `isExpired` applies a 60 s skew so we refresh slightly early rather than mid-request.
struct OuraTokens: Equatable, Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

/// Keychain Services wrapper for the Oura tokens. One generic-password item (JSON-encoded `OuraTokens`)
/// under a fixed service, so tokens never land in UserDefaults, a plist, or on disk in the clear.
/// Mirrors AIKeyStore exactly (delete-then-add, kSecAttrAccessibleAfterFirstUnlock).
enum OuraTokenStore {
    private static let service = "com.noop.oura"
    private static let account = "oauth-tokens"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or replace) the tokens. Returns false if the Keychain write fails (so callers never assume
    /// a token is stored when it isn't).
    @discardableResult
    static func save(_ tokens: OuraTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Load the stored tokens, or nil if none.
    static func load() -> OuraTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let tokens = try? JSONDecoder().decode(OuraTokens.self, from: data) else { return nil }
        return tokens
    }

    /// Remove any stored tokens.
    static func clear() { SecItemDelete(baseQuery as CFDictionary) }

    /// True when tokens are present (regardless of expiry — an expired token is still "connected", it
    /// just needs a refresh).
    static var isConnected: Bool { load() != nil }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraTokenStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: PASS (`Test Suite 'OuraTokenStoreTests' passed`). If the Keychain is unavailable in the test host and `save` returns false, note it in the report — the AICoach Keychain tests establish that the host allows it; if they pass and this doesn't, investigate before proceeding.

- [ ] **Step 6: Commit**

```bash
git add Strand/Oura/OuraError.swift Strand/Oura/OuraTokenStore.swift StrandTests/OuraTokenStoreTests.swift
git commit -m "feat(oura): OuraError + OuraTokenStore (Keychain token storage)"
```

---

### Task 2: `OuraCredentials` + `AuthProvider` protocol

Read the BYO-app credentials from Info.plist (injected via xcconfig in Task 5) and define the auth seam.

**Files:**
- Create: `Strand/Oura/OuraCredentials.swift`
- Create: `Strand/Oura/AuthProvider.swift`
- Test: `StrandTests/OuraCredentialsTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `struct OuraCredentials: Equatable { let clientId: String; let clientSecret: String; let redirectURI: String }` with `static func from(_ info: [String: Any]) -> OuraCredentials?` (nil if any key missing/blank) and `static var fromBundle: OuraCredentials?` (reads `Bundle.main.infoDictionary`).
  - `protocol AuthProvider { var isConnected: Bool { get }; func validAccessToken() async throws -> String; func authorize(presentationAnchor: ASPresentationAnchor) async throws; func signOut() }`

- [ ] **Step 1: Write the failing test**

Create `StrandTests/OuraCredentialsTests.swift`:

```swift
import XCTest
@testable import Strand

final class OuraCredentialsTests: XCTestCase {
    func testParsesCompleteInfoDict() {
        let info: [String: Any] = [
            "OURA_CLIENT_ID": "cid", "OURA_CLIENT_SECRET": "secret",
            "OURA_REDIRECT_URI": "noop://oura/callback",
        ]
        let c = OuraCredentials.from(info)
        XCTAssertEqual(c, OuraCredentials(clientId: "cid", clientSecret: "secret",
                                          redirectURI: "noop://oura/callback"))
    }

    func testNilWhenAnyKeyMissingOrBlank() {
        XCTAssertNil(OuraCredentials.from(["OURA_CLIENT_ID": "cid", "OURA_CLIENT_SECRET": "s"]))  // no redirect
        XCTAssertNil(OuraCredentials.from([
            "OURA_CLIENT_ID": "", "OURA_CLIENT_SECRET": "s", "OURA_REDIRECT_URI": "noop://x",
        ]))  // blank id
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraCredentialsTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: FAIL — `OuraCredentials` undefined.

- [ ] **Step 3: Implement `OuraCredentials`**

Create `Strand/Oura/OuraCredentials.swift`:

```swift
import Foundation

/// The user's own Oura OAuth app credentials, injected at build time via an untracked xcconfig →
/// Info.plist (Task 5). Absent credentials mean the Connect flow is unavailable (surfaced in the UI).
struct OuraCredentials: Equatable {
    let clientId: String
    let clientSecret: String
    let redirectURI: String

    /// Build from an Info-dictionary-shaped map. Returns nil unless all three keys are present and
    /// non-blank (so a build without the xcconfig cleanly disables the lane rather than half-configuring).
    static func from(_ info: [String: Any]) -> OuraCredentials? {
        func nonBlank(_ key: String) -> String? {
            guard let s = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return nil }
            return s
        }
        guard let id = nonBlank("OURA_CLIENT_ID"),
              let secret = nonBlank("OURA_CLIENT_SECRET"),
              let redirect = nonBlank("OURA_REDIRECT_URI") else { return nil }
        return OuraCredentials(clientId: id, clientSecret: secret, redirectURI: redirect)
    }

    /// The live credentials from the app bundle's Info.plist, or nil if not configured.
    static var fromBundle: OuraCredentials? { from(Bundle.main.infoDictionary ?? [:]) }
}
```

- [ ] **Step 4: Implement `AuthProvider`**

Create `Strand/Oura/AuthProvider.swift`:

```swift
import Foundation
import AuthenticationServices

/// The auth seam. Today's concrete provider is `OuraOAuthProvider` (BYO-app authorization-code, Task 3);
/// a future backend-mediated provider can replace it without touching the API client or the sync layer.
protocol AuthProvider {
    /// True when tokens are stored (connected), regardless of expiry.
    var isConnected: Bool { get }
    /// Return a currently-valid access token, refreshing transparently if the stored one is expired.
    func validAccessToken() async throws -> String
    /// Run the interactive authorization (opens Oura's consent page) and store the resulting tokens.
    @MainActor func authorize(presentationAnchor: ASPresentationAnchor) async throws
    /// Forget the stored tokens (disconnect).
    func signOut()
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraCredentialsTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Strand/Oura/OuraCredentials.swift Strand/Oura/AuthProvider.swift StrandTests/OuraCredentialsTests.swift
git commit -m "feat(oura): OuraCredentials (Info.plist) + AuthProvider seam"
```

---

### Task 3: OAuth pure builders + `OuraOAuthProvider`

The authorization-code flow: pure URL/body builders + token-response parser (unit-tested), plus the provider that runs `ASWebAuthenticationSession` and the token-exchange POST.

**Files:**
- Create: `Strand/Oura/OuraOAuth.swift` (pure builders/parser)
- Create: `Strand/Oura/OuraOAuthProvider.swift` (`AuthProvider` impl)
- Test: `StrandTests/OuraOAuthTests.swift`

**Interfaces:**
- Consumes: `OuraCredentials`, `OuraTokens`, `OuraTokenStore`, `OuraError`, `AuthProvider`.
- Produces:
  - `enum OuraOAuth` with pure statics: `authorizeURL(credentials:state:) -> URL`, `tokenExchangeRequest(credentials:code:) -> URLRequest`, `refreshRequest(credentials:refreshToken:) -> URLRequest`, `parseTokenResponse(_ data: Data, now: Date) throws -> OuraTokens`, and `static let scopes: [String]`.
  - `final class OuraOAuthProvider: AuthProvider` (init `credentials:session:`).

- [ ] **Step 1: Write the failing test**

Create `StrandTests/OuraOAuthTests.swift`:

```swift
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

    func testParseTokenResponseThrowsOnMissingAccessToken() {
        let json = #"{"error":"invalid_grant"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try OuraOAuth.parseTokenResponse(json, now: Date()))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraOAuthTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: FAIL — `OuraOAuth` undefined.

- [ ] **Step 3: Implement the pure builders/parser**

Create `Strand/Oura/OuraOAuth.swift`:

```swift
import Foundation

/// Pure (network-free) pieces of the Oura OAuth2 authorization-code flow: URL/request builders and the
/// token-response parser. Unit-tested directly; the interactive step + the actual POST live in
/// OuraOAuthProvider. No PKCE (Oura's flow doesn't support it), so the exchange carries the client_secret.
enum OuraOAuth {
    static let authorizeEndpoint = URL(string: "https://cloud.ouraring.com/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://api.ouraring.com/oauth/token")!
    static let scopes = ["email", "personal", "daily", "heartrate", "workout", "tag", "session", "spo2Daily"]

    /// The consent URL to open in ASWebAuthenticationSession. `state` is a caller-generated nonce echoed
    /// back on redirect and verified, to defeat CSRF / stray callbacks.
    static func authorizeURL(credentials: OuraCredentials, state: String) -> URL {
        var comps = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: credentials.clientId),
            .init(name: "redirect_uri", value: credentials.redirectURI),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state),
        ]
        return comps.url!
    }

    static func tokenExchangeRequest(credentials: OuraCredentials, code: String) -> URLRequest {
        form(tokenEndpoint, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": credentials.redirectURI,
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
        ])
    }

    static func refreshRequest(credentials: OuraCredentials, refreshToken: String) -> URLRequest {
        form(tokenEndpoint, [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
        ])
    }

    /// Parse a token endpoint response. `now` is injected so expiry is deterministic in tests.
    static func parseTokenResponse(_ data: Data, now: Date) throws -> OuraTokens {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw OuraError.tokenExchangeFailed(detail)
        }
        let refresh = obj["refresh_token"] as? String
        let expiresIn = (obj["expires_in"] as? Double) ?? (obj["expires_in"] as? Int).map(Double.init) ?? 2_592_000
        return OuraTokens(accessToken: access, refreshToken: refresh,
                          expiresAt: now.addingTimeInterval(expiresIn))
    }

    private static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        return req
    }
}
```

- [ ] **Step 4: Implement `OuraOAuthProvider`**

Create `Strand/Oura/OuraOAuthProvider.swift`:

```swift
import Foundation
import AuthenticationServices

/// BYO-app OAuth2 authorization-code AuthProvider. Runs ASWebAuthenticationSession for the interactive
/// consent, exchanges the code for tokens (Keychain), and refreshes on demand. The `session` is injected
/// so the token exchange/refresh POSTs are URLProtocol-testable; the interactive step is integration-only.
final class OuraOAuthProvider: NSObject, AuthProvider, ASWebAuthenticationPresentationContextProviding {
    private let credentials: OuraCredentials
    private let session: URLSession
    private var anchor: ASPresentationAnchor?

    init(credentials: OuraCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    var isConnected: Bool { OuraTokenStore.isConnected }
    func signOut() { OuraTokenStore.clear() }

    func validAccessToken() async throws -> String {
        guard let tokens = OuraTokenStore.load() else { throw OuraError.notConnected }
        if !tokens.isExpired { return tokens.accessToken }
        guard let refresh = tokens.refreshToken else { throw OuraError.notConnected }
        let req = OuraOAuth.refreshRequest(credentials: credentials, refreshToken: refresh)
        let refreshed = try await exchange(req)
        _ = OuraTokenStore.save(refreshed)
        return refreshed.accessToken
    }

    @MainActor
    func authorize(presentationAnchor: ASPresentationAnchor) async throws {
        self.anchor = presentationAnchor
        let state = UUID().uuidString
        let url = OuraOAuth.authorizeURL(credentials: credentials, state: state)
        let scheme = URL(string: credentials.redirectURI)?.scheme

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let webSession = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, err in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: OuraError.authFailed(err?.localizedDescription ?? "cancelled")) }
            }
            webSession.presentationContextProvider = self
            webSession.prefersEphemeralWebBrowserSession = false
            if !webSession.start() { cont.resume(throwing: OuraError.authFailed("couldn't start web session")) }
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard q["state"] == state else { throw OuraError.authFailed("state mismatch") }
        guard let code = q["code"], !code.isEmpty else { throw OuraError.authFailed(q["error"] ?? "no code") }

        let tokens = try await exchange(OuraOAuth.tokenExchangeRequest(credentials: credentials, code: code))
        guard OuraTokenStore.save(tokens) else { throw OuraError.tokenExchangeFailed("keychain write failed") }
    }

    /// POST a token request and parse the response (shared by exchange + refresh).
    private func exchange(_ req: URLRequest) async throws -> OuraTokens {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw OuraError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw OuraError.tokenExchangeFailed("HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try OuraOAuth.parseTokenResponse(data, now: Date())
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraOAuthTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: PASS (4 tests). Note in the report: `OuraOAuthProvider.authorize` (the interactive ASWebAuthenticationSession step) is compile-verified here but exercised only in live/integration testing — its pure inputs (`authorizeURL`, exchange request, response parse) and the exchange POST path are what the tests cover.

- [ ] **Step 6: Commit**

```bash
git add Strand/Oura/OuraOAuth.swift Strand/Oura/OuraOAuthProvider.swift StrandTests/OuraOAuthTests.swift
git commit -m "feat(oura): OAuth2 authorization-code flow (pure builders + OuraOAuthProvider)"
```

---

### Task 4: `OuraAPIClient` — paging + backoff

The `URLSession` client: per-endpoint fetch, `next_token` paging, 429 backoff, 401 refresh-once, prod/sandbox base URL. Pure envelope parser split out for unit tests; the networked paths driven by a `URLProtocol` stub.

**Files:**
- Create: `Strand/Oura/OuraAPIClient.swift`
- Create: `StrandTests/OuraURLProtocolStub.swift` (reusable stub)
- Test: `StrandTests/OuraAPIClientTests.swift`

**Interfaces:**
- Consumes: `AuthProvider`, `OuraError`.
- Produces:
  - `enum OuraEnvironment { case production, sandbox; var baseURL: String }`
  - `struct OuraPage { let data: [[String: Any]]; let nextToken: String? }` — intentionally NOT `Equatable` (`[[String: Any]]` isn't); tests assert on `.count`/fields.
  - `enum OuraAPI` pure: `static func parsePage(_ data: Data) throws -> OuraPage`.
  - `final class OuraAPIClient` init `auth:environment:session:` with `func fetchAll(endpoint: String, query: [String: String]) async throws -> [[String: Any]]` (follows `next_token`, returns concatenated `data`), and `func fetchAllRaw(endpoint:query:) async throws -> [Data]` (the verbatim page bodies for Plan 3's raw archive).

- [ ] **Step 1: Write the failing test + the URLProtocol stub**

Create `StrandTests/OuraURLProtocolStub.swift`:

```swift
import Foundation

/// Test-only URLProtocol that serves canned responses by request order, so the paging loop and
/// status-code handling are driven deterministically without a live socket.
final class OuraURLProtocolStub: URLProtocol {
    struct Stubbed { let status: Int; let body: Data }
    /// FIFO queue of responses; each request pops the next. Set before the test acts.
    nonisolated(unsafe) static var queue: [Stubbed] = []
    /// Captured request URLs, in order, for assertions.
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    static func reset() { queue = []; requestedURLs = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let u = request.url { Self.requestedURLs.append(u) }
        let s = Self.queue.isEmpty ? Stubbed(status: 500, body: Data()) : Self.queue.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: s.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: s.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// A URLSession wired to this stub.
    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [OuraURLProtocolStub.self]
        return URLSession(configuration: cfg)
    }
}
```

Create `StrandTests/OuraAPIClientTests.swift`:

```swift
import XCTest
import AuthenticationServices
@testable import Strand

/// A stub AuthProvider that hands out a fixed token and counts refreshes.
private final class StubAuth: AuthProvider {
    var token = "tok-1"
    var validCalls = 0
    var isConnected: Bool { true }
    func validAccessToken() async throws -> String { validCalls += 1; return token }
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraAPIClientTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: FAIL — `OuraAPIClient` / `OuraAPI` undefined.

- [ ] **Step 3: Implement `OuraAPIClient`**

Create `Strand/Oura/OuraAPIClient.swift`:

```swift
import Foundation

enum OuraEnvironment {
    case production, sandbox
    var baseURL: String {
        switch self {
        case .production: return "https://api.ouraring.com/v2/usercollection"
        case .sandbox:    return "https://api.ouraring.com/v2/sandbox/usercollection"
        }
    }
}

/// One decoded page of an Oura list/time-series response.
struct OuraPage {
    let data: [[String: Any]]
    let nextToken: String?
}

/// Pure (network-free) response-envelope parsing, unit-tested directly.
enum OuraAPI {
    static func parsePage(_ data: Data) throws -> OuraPage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OuraError.decode
        }
        let rows = (obj["data"] as? [[String: Any]]) ?? []
        return OuraPage(data: rows, nextToken: obj["next_token"] as? String)
    }
}

/// The Oura v2 API client. Injected `AuthProvider` supplies the bearer token (refreshing on expiry);
/// injected `session` makes it URLProtocol-testable. Follows `next_token` paging, retries 429 with a
/// bounded backoff, and refreshes-once on 401. Networking lives here in the app target by design.
final class OuraAPIClient {
    private let auth: AuthProvider
    private let environment: OuraEnvironment
    private let session: URLSession
    private let backoff: TimeInterval
    private let maxPages = 10_000   // runaway guard (logged if hit)

    init(auth: AuthProvider, environment: OuraEnvironment = .production,
         session: URLSession = .shared, backoff: TimeInterval = 2) {
        self.auth = auth
        self.environment = environment
        self.session = session
        self.backoff = backoff
    }

    /// Fetch every page of `endpoint` for `query`, following `next_token`, returning concatenated rows.
    func fetchAll(endpoint: String, query: [String: String]) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        try await forEachPage(endpoint: endpoint, query: query) { page in rows.append(contentsOf: page.data) }
        return rows
    }

    /// Fetch every page, returning the verbatim page bodies (for Plan 3's lossless raw archive).
    func fetchAllRaw(endpoint: String, query: [String: String]) async throws -> [Data] {
        var bodies: [Data] = []
        try await forEachPage(endpoint: endpoint, query: query, rawSink: { bodies.append($0) }) { _ in }
        return bodies
    }

    private func forEachPage(endpoint: String, query: [String: String],
                             rawSink: ((Data) -> Void)? = nil,
                             _ handle: (OuraPage) -> Void) async throws {
        var next: String? = nil
        var pages = 0
        repeat {
            var q = query
            if let next { q["next_token"] = next }
            let (data, _) = try await getWithRetry(endpoint: endpoint, query: q)
            rawSink?(data)
            let page = try OuraAPI.parsePage(data)
            handle(page)
            next = page.nextToken
            pages += 1
            if pages >= maxPages { break }   // Plan-3 note: log if this cap is ever hit.
        } while next != nil
    }

    /// GET with auth + 429-backoff + 401-refresh-once. Returns (body, status).
    private func getWithRetry(endpoint: String, query: [String: String]) async throws -> (Data, Int) {
        for attempt in 0..<3 {
            let token = try await auth.validAccessToken()
            let (data, code) = try await get(endpoint: endpoint, query: query, token: token)
            switch code {
            case 200..<300:
                return (data, code)
            case 429:
                if backoff > 0 { try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000)) }
                continue
            case 401 where attempt == 0:
                _ = try? await auth.validAccessToken()   // force a refresh, then retry once
                continue
            default:
                throw OuraError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
            }
        }
        throw OuraError.rateLimited
    }

    private func get(endpoint: String, query: [String: String], token: String) async throws -> (Data, Int) {
        var comps = URLComponents(string: "\(environment.baseURL)/\(endpoint)")!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await session.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw OuraError.network(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraAPIClientTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Strand/Oura/OuraAPIClient.swift StrandTests/OuraURLProtocolStub.swift StrandTests/OuraAPIClientTests.swift
git commit -m "feat(oura): OuraAPIClient — next_token paging, 429 backoff, 401 refresh, sandbox/prod"
```

---

### Task 5: Wiring — Info.plist redirect scheme + xcconfig credentials

Register the OAuth redirect URL scheme and wire the untracked credentials xcconfig. No unit test (build config); verify the app still generates + builds.

**Files:**
- Modify: `project.yml` (add `CFBundleURLTypes` to the `Strand` and `NOOPiOS` targets' Info settings + reference the xcconfig)
- Create: `Strand/Oura/OuraSecrets.example.xcconfig` (committed template)
- Modify: `.gitignore` (ignore `Strand/Oura/OuraSecrets.xcconfig`)

**Interfaces:** none (configuration). Provides the Info.plist keys `OURA_CLIENT_ID`/`OURA_CLIENT_SECRET`/`OURA_REDIRECT_URI` and the `noop` URL scheme that Tasks 2–3 read.

- [ ] **Step 1: Add the example xcconfig**

Create `Strand/Oura/OuraSecrets.example.xcconfig`:

```
// Copy to OuraSecrets.xcconfig (gitignored) and fill in your own Oura OAuth app's values.
// Register a free app at the Oura developer portal; set the redirect URI to noop://oura/callback.
OURA_CLIENT_ID = your_client_id_here
OURA_CLIENT_SECRET = your_client_secret_here
OURA_REDIRECT_URI = noop://oura/callback
```

- [ ] **Step 2: Ignore the real xcconfig**

Add to `.gitignore` (append):

```
# Oura BYO-app OAuth credentials (never committed)
Strand/Oura/OuraSecrets.xcconfig
```

- [ ] **Step 3: Wire the xcconfig + URL scheme in `project.yml`**

Under the `Strand` target (and the same under `NOOPiOS`), reference the xcconfig via `configFiles` and add the Info.plist keys. Add to the target's `settings` / `info` block:

```yaml
    # (within target: Strand)
    configFiles:
      Debug: Strand/Oura/OuraSecrets.xcconfig
      Release: Strand/Oura/OuraSecrets.xcconfig
    info:
      path: Strand/Resources/Info.plist
      properties:
        OURA_CLIENT_ID: $(OURA_CLIENT_ID)
        OURA_CLIENT_SECRET: $(OURA_CLIENT_SECRET)
        OURA_REDIRECT_URI: $(OURA_REDIRECT_URI)
        CFBundleURLTypes:
          - CFBundleURLSchemes: [noop]
```

(If `configFiles` already exists on the target, merge these keys in. The exact YAML location must match the existing `project.yml` structure — read it first.)

- [ ] **Step 4: Verify generate + build**

Create an `OuraSecrets.xcconfig` with placeholder values (so the build resolves the variables), then:

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' build-for-testing CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: `** TEST BUILD SUCCEEDED **`. Then confirm the Info.plist keys resolve: the `OuraCredentials.fromBundle` path will read them at runtime.

- [ ] **Step 5: Commit**

```bash
git add project.yml .gitignore Strand/Oura/OuraSecrets.example.xcconfig
git commit -m "chore(oura): wire OAuth redirect scheme + BYO-app credentials xcconfig"
```

---

## Plan 2 self-review

- **Spec coverage:** §5 auth (BYO-app, ASWebAuthenticationSession, Keychain, AuthProvider seam) → T1/T2/T3; §6 API client (paging, 429/401, prod/sandbox, bounded) → T4; §5.3 credentials (xcconfig→Info.plist) → T2/T5; redirect scheme → T5. `fetchAllRaw` (T4) is the seam Plan 3's writer consumes for the lossless archive.
- **Constraints:** networking confined to `Strand/Oura/`; no package touched; tokens Keychain-only; `session` injected everywhere (URLProtocol-testable); no PKCE (secret in the exchange, sourced from the user's own untracked xcconfig).
- **Interactive boundary is honest:** `OuraOAuthProvider.authorize`'s ASWebAuthenticationSession step is compile-verified + integration-tested, not unit-tested; everything around it (URL/body builders, token parse, exchange POST, paging, backoff, refresh) IS unit-tested via pure functions + the URLProtocol stub.
- **Type consistency:** `OuraTokens`/`OuraCredentials`/`OuraError` defined in T1/T2 and consumed unchanged in T3/T4; `AuthProvider` defined T2, implemented T3, injected T4; `OuraPage` is intentionally NOT `Equatable` (holds `[[String: Any]]`) — tests assert on fields.
- **Build reality:** every test step uses `xcodebuild -only-testing:StrandTests/<Class>` (first build full, then incremental); `swift test` is NOT used here (app target, not a package).

## What Plan 3 adds (next)

`OuraSyncCoordinator` (one-time backfill across all ~18 endpoints via `OuraAPIClient.fetchAllRaw` + parse via Plan 1's `OuraApiParser`) → `OuraSyncWriter` (raw archive via `upsertOuraRaw`; normalized via `upsertDailyMetrics`/`upsertSleepSessions`(+stagesJSON via decoded stages, +`persistSessionMotion`)/`upsertMetricSeries`/`insert(hrSample)`/`upsertWorkouts`; register `PairedDevice(sourceKind: .cloudImport)`; **coalesce** per-day rows, prefer readiness RHR, map sleep-score/vo2max onto the daily columns — per the Plan-1 final-review advisories) → the "Connect Oura & Import Everything" UI on `DataSourcesView` + progress/summary/disconnect → doc updates (`PRIVACY_SECURITY.md` second opt-in lane, `DEVICE_SUPPORT_ROADMAP.md`, `DATA_MODEL.md` v24 `ouraRaw`).
