import Foundation

/// User-facing failure reasons for the Hevy lane, mapped to messages that say what to DO.
///
/// Mirrors `OuraError` / `AICoachError` in shape (LocalizedError + errorDescription). The reason each
/// case exists rather than one generic "sync failed": the two most likely failures are both fixable by
/// the user and indistinguishable without help — a key typed wrong, and a key that is genuinely valid
/// but belongs to an account without Hevy Pro, which is the only tier the public API serves. A single
/// message would send someone hunting through the wrong settings screen.
enum HevyError: LocalizedError, Equatable {
    case notConnected
    /// 401: the key is missing, mistyped, or has been revoked.
    case unauthorized
    /// 403: the key authenticates but the account cannot use the API. Hevy restricts it to Pro.
    case notPro
    case rateLimited
    case badResponse(Int, String)
    case network(String)
    case decode

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Connect Hevy first: paste your API key in Data Sources.")
        case .unauthorized:
            return String(localized: "Hevy rejected the API key. Check it at hevy.com/settings?developer and paste it again.")
        case .notPro:
            return String(localized: "Hevy's API is only available to Hevy Pro accounts. Your key is valid, but this account cannot use it.")
        case .rateLimited:
            return String(localized: "Hevy is rate-limiting requests. NOOP will wait and try again.")
        case .badResponse(let code, let detail):
            let extra = detail.isEmpty ? "" : " — \(detail)"
            return String(localized: "Hevy returned an error (\(code))\(extra).")
        case .network(let detail):
            return String(localized: "Network problem talking to Hevy: \(detail)")
        case .decode:
            return String(localized: "Couldn't read Hevy's response.")
        }
    }

    /// True when retrying later could plausibly succeed without the user doing anything. Drives whether
    /// the sync state offers "try again" or asks for a new key.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .network: return true
        case .badResponse(let code, _): return code >= 500
        default: return false
        }
    }
}
