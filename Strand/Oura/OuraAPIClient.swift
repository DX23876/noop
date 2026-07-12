// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
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
                _ = try? await auth.refreshedAccessToken()   // force a real refresh; the loop-top re-reads the saved token
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
#endif // OURA_CLOUD_IMPORT
