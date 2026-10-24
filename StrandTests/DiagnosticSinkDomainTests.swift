import XCTest
import StrandAnalytics
@testable import Strand

@MainActor
final class DiagnosticSinkDomainTests: XCTestCase {

    // The engine's diagnostics go through its `AnalysisHost`; the app host forwards each line with its
    // TestDomain to the sink `AppModel` wires to the strap log.
    func testSinkForwardsDomain() {
        var captured: [(String, TestDomain?)] = []
        let host = AppAnalysisHost()
        host.diagnosticSink = { line, domain in captured.append((line, domain)) }
        // Construct the engine with the project's real, lightweight in-memory dependencies.
        let engine = IntelligenceEngine(repo: Repository(deviceId: "test"), profile: ProfileStore(), deviceId: "test",
                                        host: host)
        engine.host.diagnostic("rest sub-scores dur=.5", domain: .sleep)
        engine.host.diagnostic("untagged line", domain: nil)
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].0, "rest sub-scores dur=.5")
        XCTAssertEqual(captured[0].1, .sleep)
        XCTAssertNil(captured[1].1)
    }
}
