// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
import Foundation

/// Pure (network-free) pieces of the Oura OAuth2 authorization-code flow: URL/request builders and the
/// token-response parser. Unit-tested directly; the interactive step + the actual POST live in
/// OuraOAuthProvider. No PKCE (Oura's flow doesn't support it), so the exchange carries the client_secret.
enum OuraOAuth {
    static let authorizeEndpoint = URL(string: "https://cloud.ouraring.com/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://api.ouraring.com/oauth/token")!
    // Explicit data-minimizing scope list. Do not omit `scope`: Oura treats a blank scope as "all
    // scopes configured on the app", which can silently grow when the developer portal adds new lanes.
    // Endpoints with newer portal-only scopes may be skipped by the coordinator until they get a
    // deliberate opt-in + scope addition.
    static let scopes = ["email", "personal", "daily", "heartrate", "workout", "tag", "session", "spo2"]

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
        // x-www-form-urlencoded: escape everything but unreserved chars. Crucially '+' (else the server
        // decodes it to a space) and the '&'/'=' separators — URLComponents.percentEncodedQuery leaves '+'
        // unescaped, which silently corrupts base64 client_secret/code/refresh_token values.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        req.httpBody = fields.map { "\(enc($0.key))=\(enc($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        return req
    }
}
#endif // OURA_CLOUD_IMPORT
