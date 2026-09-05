import Foundation
import StrandImport

/// One fetched page: the verbatim body plus how many pages the envelope says there are.
struct HevyPage {
    let body: Data
    let pageCount: Int
}

/// Abstracts the fetch so the coordinator is testable without a live network.
protocol HevyFetching {
    func get(path: String, query: [String: String]) async throws -> Data
    func post(path: String, body: Data) async throws -> Data
    func put(path: String, body: Data) async throws -> Data
}

/// The Hevy public API v1 client.
///
/// Deliberately small: one header, one base URL, page-numbered paging. Hevy uses a plain `api-key`
/// header rather than OAuth, so there is no token refresh, no expiry and no browser round trip — which
/// is why this has none of `OuraOAuthProvider`'s machinery.
///
/// PAGE SIZES ARE THE ENDPOINT'S, NOT OURS. The documentation caps workouts, events and routines at
/// **10** per page and exercise templates at **100**. Asking for more is a 400, so the limits are
/// named constants here rather than a hopeful number at each call site.
///
/// Networking lives in the app target by design — `StrandImport` stays pure and Linux-testable, and
/// every response this fetches is handed to `HevyApiParser` there.
final class HevyAPIClient: HevyFetching {

    /// Max items per page, per Hevy's own documentation. Exceeding either is rejected.
    static let listPageSize = 10
    static let templatePageSize = 100

    private let baseURL = "https://api.hevyapp.com/v1"
    private let keyProvider: () -> String?
    private let session: URLSession
    private let backoff: TimeInterval
    /// Runaway guard. A page-numbered API with a wrong `page_count` could otherwise loop forever; at
    /// 10 per page this still allows 20 000 workouts.
    private let maxPages = 2_000

    init(keyProvider: @escaping () -> String? = { HevyCredentials.load() },
         session: URLSession = .shared, backoff: TimeInterval = 2) {
        self.keyProvider = keyProvider
        self.session = session
        self.backoff = backoff
    }

    // MARK: - Requests

    func get(path: String, query: [String: String]) async throws -> Data {
        try await send(path: path, query: query, method: "GET", body: nil)
    }

    func post(path: String, body: Data) async throws -> Data {
        try await send(path: path, query: [:], method: "POST", body: body)
    }

    func put(path: String, body: Data) async throws -> Data {
        try await send(path: path, query: [:], method: "PUT", body: body)
    }

    /// One request with a bounded 429 backoff.
    ///
    /// 401 and 403 are NOT retried and are mapped to distinct errors: a rejected key and a valid key on
    /// a non-Pro account are both permanent until the user acts, and retrying either just delays
    /// telling them so.
    private func send(path: String, query: [String: String], method: String, body: Data?) async throws -> Data {
        guard let key = keyProvider(), !key.isEmpty else { throw HevyError.notConnected }

        for _ in 0..<3 {
            var comps = URLComponents(string: baseURL + path)
            if !query.isEmpty {
                comps?.queryItems = query.sorted { $0.key < $1.key }
                    .map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            guard let url = comps?.url else { throw HevyError.decode }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(key, forHTTPHeaderField: "api-key")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let data: Data
            let code: Int
            do {
                let (d, response) = try await session.data(for: request)
                data = d
                code = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                throw HevyError.network(error.localizedDescription)
            }

            switch code {
            case 200..<300:
                return data
            case 401:
                throw HevyError.unauthorized
            case 403:
                throw HevyError.notPro
            case 429:
                if backoff > 0 { try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000)) }
                continue
            default:
                // The body is included because Hevy's error messages are usually specific enough to
                // act on, and a bare status code sends the reader to the wrong place.
                throw HevyError.badResponse(code, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
            }
        }
        throw HevyError.rateLimited
    }

    // MARK: - Paging

    /// Walk every page of a paginated list endpoint, handing each body to `handle`.
    ///
    /// Stops at `page_count` from the FIRST page rather than probing for an empty page: Hevy reports the
    /// total up front, and one extra request per sync to rediscover it is a request the documentation
    /// asks us not to spend.
    func forEachPage(path: String, query: [String: String] = [:], pageSize: Int,
                     onPage: (Data, _ index: Int, _ total: Int) -> Void) async throws {
        var page = 1
        var total = 1
        repeat {
            var q = query
            q["page"] = "\(page)"
            q["pageSize"] = "\(pageSize)"
            let body = try await get(path: path, query: q)
            if page == 1 { total = min(HevyApiParser.pageCount(body), maxPages) }
            onPage(body, page, total)
            page += 1
        } while page <= total
    }

    // MARK: - Convenience reads

    /// The account's total workout count. Used to show honest progress during the first backfill, and
    /// as the acceptance check that a sync got everything.
    func workoutCount() async throws -> Int {
        let data = try await get(path: "/workouts/count", query: [:])
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = root["workout_count"] as? Int else { throw HevyError.decode }
        return count
    }

    /// A cheap authenticated call, for "test this key" before storing it. `/user/info` returns a tiny
    /// document and touches no training data, so a failed connection attempt reads nothing it need not.
    func verifyKey() async throws {
        _ = try await get(path: "/user/info", query: [:])
    }
}
