import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StrandCore

/// The Android stand-in for `URLSession.bytes(for:)` (parity plan 1.2, Coach): the head first, then the body as it
/// streams, readable by byte and by server-sent-event line, compared with what `AsyncBytes` gives on Apple.
final class StreamedBytesTests: XCTestCase {
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var chunks: [String] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in Self.chunks { client?.urlProtocol(self, didLoad: Data(chunk.utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    func testEventLinesArriveAcrossChunksAsAsyncBytesHandsThem() async throws {
        // A line split over two chunks, a CRLF, a blank separator and a last line without a feed.
        Stub.status = 200
        Stub.chunks = ["event: message_start\ndata: {\"a\"", ":1}\r\n\n", "data: [DONE]"]
        let (bytes, response) = try await session().streamedBytes(for: URLRequest(url: URL(string: "https://example.invalid/v1")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var lines: [String] = []
        for try await line in bytes.lines { lines.append(line) }
        XCTAssertEqual(lines, ["event: message_start", "data: {\"a\":1}", "data: [DONE]"])
    }

    func testARejectedBodyReadsByteByByte() async throws {
        Stub.status = 400
        Stub.chunks = ["{\"error\":", "{\"message\":\"bad field\"}}"]
        let (bytes, response) = try await session().streamedBytes(for: URLRequest(url: URL(string: "https://example.invalid/v1")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"error\":{\"message\":\"bad field\"}}")
    }
}
