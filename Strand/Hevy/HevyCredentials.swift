import Foundation
import Security

/// Keychain Services wrapper for the Hevy API key. One generic-password item under a fixed service, so
/// the key never lands in UserDefaults, a plist, or a backup file in the clear.
///
/// Mirrors `OuraTokenStore` and `AIKeyStore` exactly: delete-then-add, `ThisDeviceOnly` accessibility.
/// `ThisDeviceOnly` is the deliberate part — the key does not travel to another device in an iCloud
/// Keychain sync, so connecting Hevy on the phone does not silently connect it on the Mac too. It also
/// keeps the key out of `.noopbak`, which is a plain archive of the user's own data and has no business
/// carrying a live credential.
enum HevyCredentials {
    private static let service = "com.noop.hevy"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or replace) the key. Returns false when the Keychain write fails, so a caller never
    /// reports "connected" for a key that was not actually saved.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// The stored key, or nil.
    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    static func clear() { SecItemDelete(baseQuery as CFDictionary) }

    static var isConnected: Bool { load() != nil }

    /// A redacted form for a settings row: enough to recognise which key is stored, not enough to be
    /// one. Never log the key itself — a key in a diagnostic bundle is a key the user has to rotate.
    static func redacted(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return String(repeating: "•", count: max(trimmed.count, 4)) }
        return trimmed.prefix(4) + "…" + trimmed.suffix(4)
    }
}
