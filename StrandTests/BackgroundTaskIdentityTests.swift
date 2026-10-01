import XCTest
@testable import Strand

/// A re-signed build whose bundle id no longer matches its Info.plist says so in the export.
///
/// `BGTaskSchedulerPermittedIdentifiers` is baked in at BUILD time as `$(PRODUCT_BUNDLE_IDENTIFIER).<suffix>`,
/// while every scheduler derives its own identifier at RUNTIME from `Bundle.main.bundleIdentifier`. That is
/// correct as built. A re-signer that rewrites `CFBundleIdentifier` and not the permitted list leaves the two
/// disagreeing, and `BGTaskScheduler.register` then refuses all four: scheduled re-score, Health write-back,
/// the Coach brief and the scheduled export go inert with no visible error anywhere.
///
/// From #2514, where a Feather-signed install appeared in Apple Health with no icon and under Inactive. The
/// app cannot register an identifier iOS has not permitted, so this reports rather than repairs. (#2553)
final class BackgroundTaskIdentityTests: XCTestCase {

    private let permitted = [
        "com.noopapp.noop.debugexport",
        "com.noopapp.noop.coachbrief",
        "com.noopapp.noop.healthwriteback",
        "com.noopapp.noop.rescore",
    ]

    func testAnUntouchedBuildReportsNothing() {
        XCTAssertNil(IOSDiagnostics.backgroundTaskIdentityFault(
            runtimeID: "com.noopapp.noop", permitted: permitted))
    }

    /// The reported shape: the re-signer rewrote the bundle id and left the permitted list alone.
    func testARewrittenBundleIdIsReportedWithBothIds() {
        let line = IOSDiagnostics.backgroundTaskIdentityFault(
            runtimeID: "com.example.noop.resigned", permitted: permitted)
        guard let line else { return XCTFail("a mismatched bundle id must be reported") }
        XCTAssertTrue(line.contains("com.example.noop.resigned"), line)
        XCTAssertTrue(line.contains("com.noopapp.noop"), "it must name the id Info.plist permits: \(line)")
        // Tracks the copy on purpose: the wording IS the diagnostic, so a reader has to be able to tell
        // at a glance that nothing will run. It was "CANNOT REGISTER" until that read as a tested outcome
        // rather than what it is, an inference from the plist. A future rewording updates this with it.
        XCTAssertTrue(line.contains("WILL NOT REGISTER"), line)
    }

    /// A build that declares no background tasks is not broken, and must not be told it is.
    func testNoPermittedIdentifiersIsNotAFault() {
        XCTAssertNil(IOSDiagnostics.backgroundTaskIdentityFault(runtimeID: "com.noopapp.noop", permitted: []))
    }

    /// A fork or staging prefix is a legitimate build, not a fault: its own id matches its own plist.
    func testAForkPrefixIsFineWhenItsPlistAgrees() {
        XCTAssertNil(IOSDiagnostics.backgroundTaskIdentityFault(
            runtimeID: "com.mine.noop",
            permitted: ["com.mine.noop.rescore", "com.mine.noop.coachbrief"]))
    }

    /// A PREFIX collision must not read as a match: `com.noopapp.noop2` is a different app, and
    /// `hasPrefix` without the dot separator would wrongly clear it.
    func testASiblingIdSharingAPrefixIsStillAFault() {
        XCTAssertNotNil(IOSDiagnostics.backgroundTaskIdentityFault(
            runtimeID: "com.noopapp.noop2", permitted: permitted))
    }

    /// Partially rewritten lists still register what they can, so that is not the failure this names.
    func testAListWithAtLeastOneMatchingIdentifierIsNotAFault() {
        XCTAssertNil(IOSDiagnostics.backgroundTaskIdentityFault(
            runtimeID: "com.noopapp.noop",
            permitted: ["com.other.app.rescore", "com.noopapp.noop.coachbrief"]))
    }
}
