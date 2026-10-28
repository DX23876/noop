import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StrandTraining
import StrandCore

final class ExerciseDBProviderClientTests: XCTestCase {
    private static let sample = #"[{"exerciseId":"body","name":" Synthetic curl ","targetMuscles":["biceps"],"equipments":["body weight"],"instructions":["Synthetic instruction"],"gifUrl":"https://media.example.invalid/demo.gif"},{"id":"loaded","name":"Loaded curl","target":"biceps","equipment":"dumbbell"}]"#
    private final class HTTP: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var hold = false
        nonisolated(unsafe) static var requests: [URLRequest] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock(); let body = Self.body, status = Self.status, hold = Self.hold; Self.requests.append(request); Self.lock.unlock()
            if hold { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        static func reset(_ status: Int, body: Data, hold: Bool = false) { lock.lock(); defer { lock.unlock() }; self.status = status; self.body = body; self.hold = hold; requests = [] }
        static func read() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }
    private func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [HTTP.self]; return value
    }

    func testAllEnvelopeShapesShareTheSameNormalizationAndNeverFetchMedia() throws {
        let direct = Data(Self.sample.utf8)
        let plain = try ExerciseDBProviderClient.parse(direct)
        for key in ["data", "exercises"] {
            let wrapped = Data("{\"\(key)\":\(Self.sample)}".utf8)
            XCTAssertEqual(try ExerciseDBProviderClient.parse(wrapped), plain)
        }
        XCTAssertEqual(plain.map(\.id), ["exercisedb:body", "exercisedb:loaded"])
        XCTAssertEqual(plain[0].title, "Synthetic curl")
        XCTAssertEqual(plain[0].mode, .bodyweightReps)
        XCTAssertEqual(plain[0].equipmentIds, ["bodyweight"])
        XCTAssertEqual(plain[0].mediaId, "https://media.example.invalid/demo.gif")
        XCTAssertEqual(plain[1].mode, .weightReps)
    }

    func testCorrectedMeasurementsKeepTheOldIdentityAndReimportsStayStable() throws {
        let incoming = try ExerciseDBProviderClient.parse(Data(Self.sample.utf8))
        let old = TrainingExercise(id: "exercisedb:body", title: "Legacy", mode: .weightReps, equipmentIds: ["body-weight"], source: .exerciseDB, sourceId: "body")
        let reviewed = try ExerciseDBProviderClient.keepingMeasurementIdentity(incoming, existing: [old])
        XCTAssertEqual(reviewed[0].id, "exercisedb:body:bodyweight_reps")
        XCTAssertEqual(old.mode, .weightReps)
        XCTAssertEqual(try ExerciseDBProviderClient.keepingMeasurementIdentity(incoming, existing: [old] + reviewed), reviewed)
        XCTAssertEqual(reviewed[0].instructions, incoming[0].instructions)
        XCTAssertEqual(reviewed[0].mediaId, incoming[0].mediaId)
    }

    func testTheRequestRejectsUnsafeEndpointsAndHeadersBeforeAnyTransport() throws {
        for endpoint in ["http://example.invalid", "file:///tmp/test", "https://user:secret@example.invalid"] {
            XCTAssertThrowsError(try ExerciseDBProviderClient.request(endpoint: endpoint, key: nil, headerName: nil))
        }
        for header in ["Bad\r\nName", "Host", "Cookie", ""] {
            XCTAssertThrowsError(try ExerciseDBProviderClient.request(endpoint: "https://example.invalid", key: "synthetic", headerName: header))
        }
        XCTAssertThrowsError(try ExerciseDBProviderClient.request(endpoint: "https://example.invalid", key: "bad\nvalue", headerName: "api-key"))
    }

    func testOneReadCarriesOnlyTheExplicitCredentialAndRejectsRedirectAndOversizeResponses() async throws {
        HTTP.reset(200, body: Data(Self.sample.utf8))
        let exercises = try await ExerciseDBProviderClient.fetch(endpoint: ExerciseDBProviderClient.defaultEndpoint,
            key: "synthetic-key", headerName: "x-rapidapi-key", configuration: configuration())
        XCTAssertEqual(exercises.count, 2)
        XCTAssertTrue(exercises.allSatisfy { $0.attribution == ExerciseDBProviderClient.defaultAttribution })
        let requests = HTTP.read(); XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-rapidapi-key"), "synthetic-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-rapidapi-host"), "oss.exercisedb.dev")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.url!.absoluteString.contains("synthetic-key"))
        HTTP.reset(302, body: Data())
        do { _ = try await ExerciseDBProviderClient.fetch(endpoint: "https://example.invalid", key: nil, headerName: nil, configuration: configuration()); XCTFail("redirects must not be followed") }
        catch ExerciseDBProviderError.invalidResponse {}
        XCTAssertEqual(HTTP.read().count, 1)
        HTTP.reset(200, body: Data(repeating: 0, count: ExerciseDBProviderClient.maximumResponseBytes + 1))
        do { _ = try await ExerciseDBProviderClient.fetch(endpoint: "https://example.invalid", key: nil, headerName: nil, configuration: configuration()); XCTFail("the receive buffer must be bounded") }
        catch ExerciseDBProviderError.limitExceeded {}
    }

    func testDuplicateIdsEmptyPagesAndCancelledReadsCannotProduceAReview() async throws {
        XCTAssertThrowsError(try ExerciseDBProviderClient.parse(Data("[]".utf8)))
        XCTAssertThrowsError(try ExerciseDBProviderClient.parse(Data(#"[{"id":"a","name":"First"},{"id":"a","name":"Second"}]"#.utf8)))
        HTTP.reset(200, body: Data(Self.sample.utf8), hold: true)
        let config = configuration()
        let task = Task { try await ExerciseDBProviderClient.fetch(endpoint: "https://example.invalid", key: nil, headerName: nil, configuration: config) }
        task.cancel()
        do { _ = try await task.value; XCTFail("a cancelled request must not become a review") } catch is CancellationError {}
    }
}
