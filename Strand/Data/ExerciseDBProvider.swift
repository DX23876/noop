import Foundation
import Security
import StrandTraining
import StrandCore

enum ExerciseDBCredentials {
    private static let service = "app.noop.training.exercisedb"
    private static let account = "personal-api-key"

    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { clear(); return true }
        let data = Data(trimmed.utf8)
        let updated = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() { SecItemDelete(baseQuery as CFDictionary) }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

// The platform owns only Keychain access; one parser and read transport serve both platforms
// (`ExerciseDBProviderClient` and `ExerciseDBProviderError` come from StrandCore).
