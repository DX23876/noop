import XCTest
import StrandCore
@testable import Strand

/// Telling somebody their own reported problem moved.
///
/// The properties under test are the four rules the watcher exists to keep: it only speaks about this
/// device's own reports, only when something really happened, it never says the same thing twice, and
/// it asks nothing of the network when it is switched off or has nothing to ask about.
final class ProjectReportWatcherTests: XCTestCase {

    private let base = URL(string: "https://relay.test")!

    private func defaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    private func store(_ defaults: UserDefaults) -> ProjectReportStore {
        ProjectReportStore(defaults: defaults)
    }

    private func service(_ body: String, calls: Counter? = nil) -> ProjectService {
        ProjectService(service: base, keyStore: ProjectDeviceKeyStore(defaults: defaults()),
                       sharing: ProjectSharing(defaults: defaults()),
                       send: { request in
            calls?.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
        func increment() { lock.lock(); stored += 1; lock.unlock() }
    }

    private func thread(status: String, messages: [(Bool, String)]) -> String {
        let rows = messages.map { #"{"mine":\#($0.0),"text":"\#($0.1)","at":"2026-11-16T01:00:00Z"}"# }
        return #"{"status":"\#(status)","fixedIn":null,"publicNumber":null,"messages":[\#(rows.joined(separator: ","))]}"#
    }

    // MARK: Only when something happened

    func testAStatusThatMovedIsNewsAndSayingItTwiceIsNot() async {
        let suite = defaults()
        let reports = store(suite)
        reports.add(.init(code: "WDYD-9TJP-2BAW-WM52", title: "Live heart rate stops", sent: Date()))

        let first = await ProjectReportWatcher.check(
            service: service(thread(status: "working", messages: [])), store: reports)
        XCTAssertEqual(first.map(\.status), [.working])
        XCTAssertFalse(first[0].answered, "a label moving is not somebody speaking")

        let again = await ProjectReportWatcher.check(
            service: service(thread(status: "working", messages: [])), store: reports)
        XCTAssertTrue(again.isEmpty, "the same state is not news a second time")
    }

    func testAnAnswerFromTheDeveloperIsNewsButMyOwnReplyIsNot() async {
        let suite = defaults()
        let reports = store(suite)
        reports.add(.init(code: "WDYD-9TJP-2BAW-WM52", title: "Live heart rate stops", sent: Date()))

        let answered = await ProjectReportWatcher.check(
            service: service(thread(status: "arrived", messages: [(false, "Which firmware?")])),
            store: reports)
        XCTAssertEqual(answered.count, 1)
        XCTAssertTrue(answered[0].answered)

        let mine = await ProjectReportWatcher.check(
            service: service(thread(status: "arrived",
                                    messages: [(false, "Which firmware?"), (true, "17.1.3")])),
            store: reports)
        XCTAssertTrue(mine.isEmpty, "answering yourself is not an answer to you")
    }

    // MARK: Asking nothing when there is nothing to ask

    func testSwitchedOffItDoesNotEvenLook() async {
        let suite = defaults()
        ProjectReportWatcher.setOn(false, defaults: suite)
        let reports = store(suite)
        reports.add(.init(code: "WDYD-9TJP-2BAW-WM52", title: "Something", sent: Date()))
        let calls = Counter()
        let changes = await ProjectReportWatcher.checkIfDue(
            service: service(thread(status: "fixed", messages: []), calls: calls),
            store: reports, defaults: suite)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(calls.value, 0)
    }

    func testItLooksAtMostEverySixHours() async {
        let suite = defaults()
        let reports = store(suite)
        reports.add(.init(code: "WDYD-9TJP-2BAW-WM52", title: "Something", sent: Date()))
        let calls = Counter()
        let now = Date()

        _ = await ProjectReportWatcher.checkIfDue(
            service: service(thread(status: "arrived", messages: []), calls: calls),
            store: reports, defaults: suite, now: now)
        let afterFirst = calls.value
        XCTAssertGreaterThan(afterFirst, 0)

        _ = await ProjectReportWatcher.checkIfDue(
            service: service(thread(status: "fixed", messages: []), calls: calls),
            store: reports, defaults: suite, now: now.addingTimeInterval(60 * 60))
        XCTAssertEqual(calls.value, afterFirst, "an hour later it does not ask again")

        _ = await ProjectReportWatcher.checkIfDue(
            service: service(thread(status: "fixed", messages: []), calls: calls),
            store: reports, defaults: suite, now: now.addingTimeInterval(7 * 60 * 60))
        XCTAssertGreaterThan(calls.value, afterFirst, "seven hours later it does")
    }

    func testWithNoReportsOfItsOwnItAsksNothing() async {
        let suite = defaults()
        let calls = Counter()
        let changes = await ProjectReportWatcher.checkIfDue(
            service: service(thread(status: "fixed", messages: []), calls: calls),
            store: store(suite), defaults: suite)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(calls.value, 0, "a device that reported nothing never calls the service")
    }

    // MARK: What it says

    func testEveryStatusHasALineAndNoneOfThemIsEmpty() {
        for status in ProjectReportStatus.allCases {
            XCTAssertFalse(ProjectReportWatcher.statusLine(status).isEmpty, "\(status)")
        }
    }
}
