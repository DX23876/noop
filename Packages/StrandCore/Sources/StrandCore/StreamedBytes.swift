import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A response body as it arrives, for the platforms whose Foundation has no `URLSession.bytes(for:)` (Android's
/// swift-corelibs FoundationNetworking, checked 2026-10-28). Built on a delegate data task, so the response comes
/// first and the body streams after it, chunk by chunk, never buffered whole. Read it byte by byte (an error body)
/// or line by line (server-sent events), as the Coach providers read `URLSession.AsyncBytes`.
public struct StreamedBytes: AsyncSequence, Sendable {
    public typealias Element = UInt8

    let chunks: AsyncThrowingStream<Data, Error>

    public struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: AsyncThrowingStream<Data, Error>.AsyncIterator
        var buffer = Data()
        var index = 0

        public mutating func next() async throws -> UInt8? {
            while index >= buffer.count {
                guard let chunk = try await chunks.next() else { return nil }
                buffer = chunk
                index = 0
            }
            defer { index += 1 }
            return buffer[buffer.startIndex + index]
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: chunks.makeAsyncIterator()) }

    /// The body split at line feeds, a carriage return before one dropped and empty lines left out, as
    /// `AsyncLineSequence` hands them to a server-sent-events reader. A last line without a line feed still counts.
    public var lines: AsyncThrowingStream<String, Error> {
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            let task = Task {
                var pending = Data()
                func emit(_ raw: Data) {
                    var line = raw
                    if line.last == 0x0D { line.removeLast() }
                    if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
                }
                do {
                    for try await chunk in chunks {
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: 0x0A) {
                            emit(pending[pending.startIndex..<newline])
                            pending = Data(pending[pending.index(after: newline)...])
                        }
                    }
                    emit(pending)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension URLSession {
    /// The response once its head arrives, and its body as it streams; the stand-in for `bytes(for:)`. The task runs
    /// on a session of its own with this session's configuration, so a caller's timeouts and headers still apply.
    public func streamedBytes(for request: URLRequest) async throws -> (StreamedBytes, URLResponse) {
        let relay = StreamRelay()
        let session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
        let response: URLResponse = try await withCheckedThrowingContinuation { continuation in
            relay.start(continuation)
            session.dataTask(with: request).resume()
        }
        session.finishTasksAndInvalidate()
        return (StreamedBytes(chunks: relay.body), response)
    }
}

/// Hands the data task's events to the caller: the response to a continuation, the body to a stream.
private final class StreamRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var head: CheckedContinuation<URLResponse, Error>?
    let body: AsyncThrowingStream<Data, Error>
    private let sink: AsyncThrowingStream<Data, Error>.Continuation

    override init() {
        var sink: AsyncThrowingStream<Data, Error>.Continuation!
        body = AsyncThrowingStream { sink = $0 }
        self.sink = sink
    }

    func start(_ continuation: CheckedContinuation<URLResponse, Error>) {
        lock.lock(); head = continuation; lock.unlock()
    }

    private func takeHead() -> CheckedContinuation<URLResponse, Error>? {
        lock.lock(); defer { lock.unlock() }
        let h = head; head = nil
        return h
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        takeHead()?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        sink.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            takeHead()?.resume(throwing: error)
            sink.finish(throwing: error)
        } else {
            // A response with no body still has a head; one that never produced one is a network failure.
            if let head = takeHead() {
                if let response = task.response { head.resume(returning: response) }
                else { head.resume(throwing: URLError(.badServerResponse)) }
            }
            sink.finish()
        }
    }
}
