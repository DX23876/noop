// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
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
        return try await refreshedAccessToken()
    }

    /// Unconditionally refresh, regardless of the stored token's expiry state.
    func refreshedAccessToken() async throws -> String {
        guard let refresh = OuraTokenStore.load()?.refreshToken else { throw OuraError.notConnected }
        let refreshed = try await exchange(OuraOAuth.refreshRequest(credentials: credentials, refreshToken: refresh))
        guard OuraTokenStore.save(refreshed) else { throw OuraError.tokenExchangeFailed("keychain write failed") }
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
#endif // OURA_CLOUD_IMPORT
