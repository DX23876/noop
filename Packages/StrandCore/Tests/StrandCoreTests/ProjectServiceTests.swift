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


/// Reporting a problem, and the switch over everything this app sends.
///
/// The promises under test: one switch stops every write, a report without a thread leaves no code
/// behind, a code is checked before it becomes a request, and the store only calls something new when
/// it actually is new, because that is what a notification is allowed to be based on.
final class ProjectReportTests: XCTestCase {

    private let base = URL(string: "https://relay.test")!

    private func keys(_ name: String = UUID().uuidString) -> ProjectDeviceKeyStore {
        ProjectDeviceKeyStore(defaults: UserDefaults(suiteName: name)!)
    }

    private func sharing(_ on: Bool) -> ProjectSharing {
        let sharing = ProjectSharing(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        sharing.set(on)
        return sharing
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

    // MARK: The one switch

    func testTheSwitchStopsEveryWriteIncludingTheThumbs() async {
        let calls = Locked(0)
        let service = ProjectService(service: base, keyStore: keys(), sharing: sharing(false),
                                     send: transport(status: 200) { _ in calls.increment() })
        let available = await service.isAvailable
        XCTAssertFalse(available, "the screens hide writing, exactly as without an address")
        let vote = await service.vote(id: "s-12", on: true)
        let wish = await service.suggest(text: "please")
        let report = await service.report(text: "it broke")
        let reply = await service.reply(code: "ABCD-EFGH-JKLM-NPQR", text: "still broken")
        XCTAssertEqual(vote, .refused)
        XCTAssertEqual(wish, .refused)
        XCTAssertEqual(report, .refused)
        XCTAssertEqual(reply, .refused)
        XCTAssertEqual(calls.value, 0, "off means nothing leaves the device, not even a thumb")
    }

    func testOnByDefault() {
        let fresh = ProjectSharing(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertTrue(fresh.isOn, "a page nobody can answer on is half a page")
    }

    // MARK: Reporting

    func testAReportCarriesTheTextTheKeyAndTheLanguageAndComesBackWithACode() async {
        let seen = Locked<String>("")
        let service = ProjectService(service: base, keyStore: keys(), sharing: sharing(true),
                                     send: transport(status: 200,
                                                     body: #"{"ok":true,"code":"WDYD-9TJP-2BAW-WM52"}"#) { request in
                                         seen.set(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
                                     })
        let result = await service.report(text: "Live heart rate stops after a reconnect", language: "de")
        XCTAssertEqual(result, .sent(code: "WDYD-9TJP-2BAW-WM52"))
        XCTAssertTrue(seen.value.contains("\"lang\":\"de\""), "the answer must come back in their language")
        XCTAssertTrue(seen.value.contains("\"thread\":true"))
        XCTAssertFalse(seen.value.contains("projectReports"), "nothing about this device travels with it")
    }

    func testAReportWithoutAThreadAsksForNoCode() async {
        let seen = Locked<String>("")
        let service = ProjectService(service: base, keyStore: keys(), sharing: sharing(true),
                                     send: transport(status: 200, body: #"{"ok":true}"#) { request in
                                         seen.set(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
                                     })
        let result = await service.report(text: "once is enough", wantsThread: false)
        XCTAssertEqual(result, .sent(code: nil))
        XCTAssertTrue(seen.value.contains("\"thread\":false"))
    }

    func testAnEmptyOrOversizedReportNeverLeaves() async {
        let calls = Locked(0)
        let service = ProjectService(service: base, keyStore: keys(), sharing: sharing(true),
                                     send: transport(status: 200) { _ in calls.increment() })
        let empty = await service.report(text: "   ")
        let huge = await service.report(text: String(repeating: "x", count: ProjectService.maximumReport + 1))
        XCTAssertEqual(empty, .refused)
        XCTAssertEqual(huge, .refused)
        XCTAssertEqual(calls.value, 0)
    }

    // MARK: The thread

    func testTheThreadIsReadAsTheServiceStatesIt() async {
        let body = #"""
        {"status":"working","fixedIn":null,"publicNumber":123,
         "messages":[{"mine":false,"text":"Which firmware?","at":"2026-11-15T10:00:00Z"},
                     {"mine":true,"text":"17.1.3","at":"2026-11-15T11:00:00Z"}]}
        """#
        let service = ProjectService(service: base, keyStore: keys(), sharing: sharing(true),
                                     send: transport(status: 200, body: body))
        let thread = await service.thread(code: "WDYD-9TJP-2BAW-WM52")
        XCTAssertEqual(thread?.status, .working)
        XCTAssertEqual(thread?.publicNumber, 123)
        XCTAssertEqual(thread?.messages.map(\.mine), [false, true])
        XCTAssertEqual(thread?.messages.last?.text, "17.1.3")
        XCTAssertNotNil(thread?.messages.first?.at, "a message without a readable time is still a message")
    }

    func testAMistypedCodeNeverBecomesARequest() async {
        let calls = Locked(0)
        let service = ProjectService(service: base, keyStore: keys(), sharing: sharing(true),
                                     send: transport(status: 200) { _ in calls.increment() })
        for bad in ["", "WDYD", "WDYD-9TJP-2BAW", "WDYD-9TJP-2BAW-WM5", "WDYD-9TJP-2BAW-WM5I",
                    "wdyd-9tjp-2baw-wm52", "WDYD-9TJP-2BAW-WM520"] {
            XCTAssertFalse(ProjectService.isReportCode(bad), bad)
            let thread = await service.thread(code: bad)
            XCTAssertNil(thread)
        }
        XCTAssertTrue(ProjectService.isReportCode("WDYD-9TJP-2BAW-WM52"))
        XCTAssertEqual(calls.value, 0)
    }

    // MARK: What the device remembers

    func testTheStoreOnlyCallsSomethingNewWhenItIsNew() {
        let store = ProjectReportStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.add(.init(code: "WDYD-9TJP-2BAW-WM52", title: "Live heart rate stops", sent: Date()))
        store.add(.init(code: "WDYD-9TJP-2BAW-WM52", title: "again", sent: Date()))
        XCTAssertEqual(store.all().count, 1, "a code is handed out once")

        XCTAssertFalse(store.seen(code: "WDYD-9TJP-2BAW-WM52", status: .arrived, messages: 0),
                       "the state it was stored with is not news")
        XCTAssertTrue(store.seen(code: "WDYD-9TJP-2BAW-WM52", status: .working, messages: 0),
                      "the status moved")
        XCTAssertTrue(store.seen(code: "WDYD-9TJP-2BAW-WM52", status: .working, messages: 1),
                      "the owner said something")
        XCTAssertFalse(store.seen(code: "WDYD-9TJP-2BAW-WM52", status: .working, messages: 1),
                       "and saying it twice is not saying it again")
        XCTAssertFalse(store.seen(code: "NOPE-NOPE-NOPE-NOPE", status: .fixed, messages: 9),
                       "a code this device never had is never news")

        store.remove(code: "WDYD-9TJP-2BAW-WM52")
        XCTAssertTrue(store.all().isEmpty)
    }
}
