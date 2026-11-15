import XCTest
@testable import StrandCore

/// The two writes the Roadmap page can make. The properties under test are the promises the page makes
/// to the person using it: nothing is sent without an address, a thumb can be taken back, the key is not
/// an identity, and a refused call is told apart from an unreachable one.
final class ProjectServiceTests: XCTestCase {

    private let base = URL(string: "https://relay.test")!

    private func store(_ name: String = UUID().uuidString) -> ProjectDeviceKeyStore {
        ProjectDeviceKeyStore(defaults: UserDefaults(suiteName: name)!)
    }

    private func transport(status: Int, body: String = "{}",
                           record: (@Sendable (URLRequest) -> Void)? = nil)
        -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            record?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    // MARK: Nothing without an address

    func testWithoutAServiceNothingIsSentAndTheFeaturesAreHidden() async {
        let calls = Locked(0)
        let service = ProjectService(service: nil, keyStore: store(),
                                     send: transport(status: 200) { _ in calls.increment() })
        let available = await service.isAvailable
        XCTAssertFalse(available)
        let vote = await service.vote(id: "s-12", on: true)
        let suggestion = await service.suggest(text: "please")
        let counts = await service.counts()
        XCTAssertEqual(vote, .refused)
        XCTAssertEqual(suggestion, .refused)
        XCTAssertTrue(counts.isEmpty)
        XCTAssertEqual(calls.value, 0, "a page without a service address must make no request at all")
    }

    // MARK: Voting

    func testAVoteSendsTheIdAndTheKeyAndNothingElse() async {
        let captured = Locked<[String: Any]>([:])
        let keys = store()
        let service = ProjectService(service: base, keyStore: keys,
                                     send: transport(status: 200, body: #"{"id":"s-12","count":3}"#) { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            captured.set(body ?? [:])
        })
        let result = await service.vote(id: "s-12", on: true)
        XCTAssertEqual(result, .sent(count: 3))
        XCTAssertEqual(Set(captured.value.keys), ["id", "on", "key"],
                       "the body carries the item, the direction and the key; nothing else may ride along")
        XCTAssertEqual(captured.value["id"] as? String, "s-12")
        XCTAssertEqual((captured.value["key"] as? String)?.count, 32)
    }

    func testAThumbIsRememberedAndCanBeTakenBack() async {
        let keys = store()
        let service = ProjectService(service: base, keyStore: keys,
                                     send: transport(status: 200, body: #"{"count":1}"#))
        _ = await service.vote(id: "s-12", on: true)
        XCTAssertTrue(keys.hasVoted("s-12"))
        _ = await service.vote(id: "s-12", on: false)
        XCTAssertFalse(keys.hasVoted("s-12"), "a vote you cannot withdraw is one people do not cast")
    }

    func testAnIdTheServiceWouldRejectNeverLeavesTheDevice() async {
        let calls = Locked(0)
        let service = ProjectService(service: base, keyStore: store(),
                                     send: transport(status: 200) { _ in calls.increment() })
        for bad in ["", "Capitals", "white space", "x", String(repeating: "a", count: 41), "semi;colon"] {
            let result = await service.vote(id: bad, on: true)
            XCTAssertEqual(result, .refused, "\(bad) should never reach the service")
        }
        XCTAssertEqual(calls.value, 0)
    }

    // MARK: Suggestions

    func testASuggestionIsBoundedAndTrimmed() async {
        let captured = Locked<[String: Any]>([:])
        let service = ProjectService(service: base, keyStore: store(),
                                     send: transport(status: 200, body: #"{"ok":true}"#) { request in
            captured.set(((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]) ?? [:])
        })
        let blank = await service.suggest(text: "   ")
        XCTAssertEqual(blank, .refused)
        let tooLong = await service.suggest(text: String(repeating: "x", count: 501))
        XCTAssertEqual(tooLong, .refused)
        let sent = await service.suggest(text: "  a dark mode for the charts \n")
        XCTAssertEqual(sent, .sent(count: nil))
        XCTAssertEqual(captured.value["text"] as? String, "a dark mode for the charts")
    }

    // MARK: What the answers mean

    func testRefusedAndUnreachableAreToldApart() async {
        let keys = store()
        for (status, expected) in [(429, ProjectServiceResult.refused), (400, .refused),
                                   (410, .unreachable), (500, .unreachable)] {
            let service = ProjectService(service: base, keyStore: keys, send: transport(status: status))
            let result = await service.vote(id: "s-12", on: true)
            XCTAssertEqual(result, expected, "status \(status)")
        }
    }

    func testARefusedVoteIsNotRememberedAsCast() async {
        let keys = store()
        let service = ProjectService(service: base, keyStore: keys, send: transport(status: 429))
        _ = await service.vote(id: "s-12", on: true)
        XCTAssertFalse(keys.hasVoted("s-12"))
    }

    func testCountsAreReadAsNumbers() async {
        let service = ProjectService(service: base, keyStore: store(),
                                     send: transport(status: 200, body: #"{"counts":{"s-1":4,"s-2":0}}"#))
        let counts = await service.counts()
        XCTAssertEqual(counts, ["s-1": 4, "s-2": 0])
    }

    // MARK: The key

    func testTheKeyIsRandomPerInstallationAndStable() {
        let first = store(), second = store()
        let a = first.key(), b = second.key()
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(a, first.key(), "the key must not change between calls")
        XCTAssertNotEqual(a, b, "two installations must not share a key")
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}

/// A tiny box so the test's transport closure can record without tripping Sendable.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
}

private extension Locked where Value == Int {
    func increment() { set(value + 1) }
}
