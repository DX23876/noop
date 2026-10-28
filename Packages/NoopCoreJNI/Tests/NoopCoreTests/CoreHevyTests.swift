import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NoopCore
import StrandCore
import StrandTraining
import WhoopStore

final class CoreHevyTests: XCTestCase {
    private final class HTTP: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var code = 200
        nonisolated(unsafe) static var body = #"{"data":{"id":"synthetic-account"}}"#
        nonisolated(unsafe) static var requests: [URLRequest] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock(); Self.requests.append(request); let code = Self.code, body = Self.body; Self.lock.unlock()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        static func reset(_ value: Int, body: String = #"{"data":{"id":"synthetic-account"}}"#) {
            lock.lock(); defer { lock.unlock() }; code = value; self.body = body; requests = []
        }
        static func read() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }
    private func client() -> CoreHevyClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HTTP.self]
        return CoreHevyClient(key: " synthetic-key ", configuration: config, backoff: 0)
    }

    func testReadTransportAuthenticatesOnlyFixedHevyEndpointsAndVerifiesTheResponse() async throws {
        HTTP.reset(200)
        try await client().verify()
        let request = try XCTUnwrap(HTTP.read().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.hevyapp.com")
        XCTAssertEqual(request.url?.path, "/v1/user/info")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "synthetic-key")
        XCTAssertFalse(request.url!.absoluteString.contains("synthetic-key"))
        HTTP.reset(200, body: "{}")
        do { try await client().verify(); XCTFail("a 200 response without an account is not verification") }
        catch HevyImportError.decode {}
        HTTP.reset(200)
        do { _ = try await client().get(path: "https://example.invalid", query: [:]); XCTFail("only the fixed import routes are allowed") }
        catch HevyImportError.decode {}
        XCTAssertTrue(HTTP.read().isEmpty)
    }

    func testAuthenticationFailuresAreNotRetriedAndRateLimitsAreBounded() async throws {
        for code in [401, 403] {
            HTTP.reset(code)
            do { try await client().verify(); XCTFail("must fail") }
            catch let error as HevyImportError { XCTAssertEqual(error, code == 401 ? .unauthorized : .notPro) }
            XCTAssertEqual(HTTP.read().count, 1)
        }
        HTTP.reset(429)
        do { try await client().verify(); XCTFail("must fail") } catch HevyImportError.rateLimited {}
        XCTAssertEqual(HTTP.read().count, 3)
    }

    func testRoutineReviewImportsOnlyTheSelectedStableCopy() async throws {
        let store = try await WhoopStore.inMemory()
        let bench = #"{"id":"r1","title":"Synthetic push","exercises":[{"title":"Bench Press (Barbell)","exercise_template_id":"T1","sets":[{"type":"normal","weight_kg":80,"reps":8}]}]}"#
        let custom = #"{"id":"r2","title":"Synthetic custom","exercises":[{"title":"Synthetic unknown movement","exercise_template_id":"CUSTOM","sets":[{"type":"normal","reps":10}]}]}"#
        let routines = [HevyRoutine(id: "r1", title: "Synthetic push", folderId: nil, notes: nil, updatedAtTs: 1, exercises: [], rawJSON: bench),
                        HevyRoutine(id: "r2", title: "Synthetic custom", folderId: nil, notes: nil, updatedAtTs: 1, exercises: [], rawJSON: custom)]
        _ = try await store.upsertHevyRoutines(routines)
        _ = try await store.upsertHevyExerciseTemplates([HevyExerciseTemplate(id: "CUSTOM", title: "Synthetic unknown movement",
            type: "reps_only", primaryMuscleGroup: .other, secondaryMuscleGroups: [], equipment: .none, isCustom: true)])
        let review = CoreHevyRoutines()
        let preview = try await review.preview(store: store)
        XCTAssertEqual(preview.routines.count, 2)
        try contract(preview, name: "hevy-routines", normalizeToken: true)
        let selected = try XCTUnwrap(preview.routines.first { $0.title == "Synthetic push" })
        let saved = try await review.accept(store: store, token: preview.token, ids: [selected.id])
        XCTAssertTrue(saved)
        let stale = try await review.accept(store: store, token: preview.token, ids: [selected.id])
        XCTAssertFalse(stale)
        let exercises = try await store.trainingExercises()
        XCTAssertFalse(exercises.contains { $0.id == "imported:hevy:CUSTOM" }, "unselected custom definitions must not leak into the library")
        let second = try await review.preview(store: store)
        let again = try await review.accept(store: store, token: second.token, ids: [selected.id])
        XCTAssertTrue(again)
        let plan = try await store.trainingPlan()
        XCTAssertEqual(plan.routines.count, 1)
        XCTAssertEqual(plan.routines[0].id.uuidString, selected.id)
        XCTAssertEqual(plan.routines[0].exercises[0].sets[0].repsMin, 8)
    }
    func testJobStatusKeepsCountsSeparateFromTheCredentialAndPayload() throws {
        var summary = HevyImportSummary()
        summary.fetchedWorkouts = 2; summary.deletedWorkouts = 1; summary.skipped = 3
        let status = CoreHevy.Status(id: "synthetic-job", state: "completed", phase: "writing", page: 1,
            totalPages: 1, summary: summary, storedWorkouts: 21)
        try contract(status, name: "hevy-status")
    }

    private func contract<T: Encodable>(_ value: T, name: String, normalizeToken: Bool = false) throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("android/app/src/test/resources/training/\(name).json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        if normalizeToken { object["token"] = "synthetic-preview" }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" { try data.write(to: file) }
        let pinned = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary
        XCTAssertEqual(object as NSDictionary, pinned)
    }

}
