// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
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
#endif // OURA_CLOUD_IMPORT
