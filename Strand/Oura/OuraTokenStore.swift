// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
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
/// Mirrors AIKeyStore exactly (delete-then-add, ThisDeviceOnly Keychain accessibility).
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
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
#endif // OURA_CLOUD_IMPORT
