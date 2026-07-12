import Foundation

/// Test-only URLProtocol that serves canned responses by request order, so the paging loop and
/// status-code handling are driven deterministically without a live socket.
final class OuraURLProtocolStub: URLProtocol {
    struct Stubbed { let status: Int; let body: Data }
    /// FIFO queue of responses; each request pops the next. Set before the test acts.
    nonisolated(unsafe) static var queue: [Stubbed] = []
    /// Captured request URLs, in order, for assertions.
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    static func reset() { queue = []; requestedURLs = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let u = request.url { Self.requestedURLs.append(u) }
        let s = Self.queue.isEmpty ? Stubbed(status: 500, body: Data()) : Self.queue.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: s.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: s.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// A URLSession wired to this stub.
    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [OuraURLProtocolStub.self]
        return URLSession(configuration: cfg)
    }
}
