import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StrandCore
import StrandImport

/// Read-only host transport. Credentials stay in memory for this explicit import, outside the core DB.
final class CoreHevyClient: HevyReadFetching {
    private let key: String
    private let session: URLSession
    private let backoff: UInt64
    private let paths: Set<String> = ["/user/info", "/workouts", "/workouts/events", "/workouts/count", "/exercise_templates", "/routines"]

    init(key: String, configuration: URLSessionConfiguration = .ephemeral, backoff: UInt64 = 2_000_000_000) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.backoff = backoff
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: HevyNoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func get(path: String, query: [String: String]) async throws -> Data {
        guard !key.isEmpty else { throw HevyImportError.notConnected }
        guard paths.contains(path) else { throw HevyImportError.decode }
        var components = URLComponents(string: "https://api.hevyapp.com/v1" + path)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw HevyImportError.decode }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(key, forHTTPHeaderField: "api-key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch {
                try Task.checkCancellation()
                throw HevyImportError.network
            }
            guard let http = response as? HTTPURLResponse else { throw HevyImportError.network }
            switch http.statusCode {
            case 200..<300:
                guard data.count <= 8 * 1024 * 1024 else { throw HevyImportError.limitExceeded }
                return data
            case 401: throw HevyImportError.unauthorized
            case 403: throw HevyImportError.notPro
            case 429:
                if attempt < 2 { try await Task.sleep(nanoseconds: backoff) }
            default: throw HevyImportError.network
            }
        }
        throw HevyImportError.rateLimited
    }

    func verify() async throws {
        let body = try await get(path: "/user/info", query: [:])
        guard HevyAPI.parseUserInfo(data: body) != nil else { throw HevyImportError.decode }
    }
}

private final class HevyNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
