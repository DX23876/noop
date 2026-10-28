import Foundation

/// Where the coach and the integrations keep a credential: one item per service and account, written whole and
/// never readable in the clear from a file or a backup. Each target that links a caller defines `secretVault()`:
/// the Keychain on Apple (`SecretVault+Keychain.swift`). Kept apart so `AIKeyStore` and `HevyCredentials` name no
/// `Security` type (Android parity plan, Coach extraction).
protocol SecretVault {
    func read(service: String, account: String) -> Data?
    /// Replaces any stored item. False when the write failed, so a caller never reports a key it did not keep.
    func write(_ data: Data, service: String, account: String) -> Bool
    func delete(service: String, account: String)
}
