import XCTest
import StrandAnalytics
@testable import Strand

/// P6: the Training Load alert posts once per high phase and never while off.
final class TrainingLoadNotifierTests: XCTestCase {
    private typealias Policy = TrainingLoadNotifier.Policy

    func testOneAlertPerHighPhase() {
        var open = false
        var posted = 0
        for band: RelativeLoadBand? in [.usual, .higher, .muchHigher, .muchHigher, .muchHigher, .higher,
                                        .muchHigher, nil, .muchHigher] {
            let decision = Policy.decide(enabled: true, band: band, episodeOpen: open)
            if decision.notify { posted += 1 }
            open = decision.episodeOpen
        }
        XCTAssertEqual(posted, 3, "three separate entries into well above usual, each posted once")
    }

    /// Off means silent — and the phase is still tracked, so switching on mid-phase does not post for a
    /// week already under way.
    func testOffIsSilentAndKeepsTrackOfThePhase() {
        let off = Policy.decide(enabled: false, band: .muchHigher, episodeOpen: false)
        XCTAssertFalse(off.notify)
        XCTAssertTrue(off.episodeOpen)
        XCTAssertFalse(Policy.decide(enabled: true, band: .muchHigher, episodeOpen: off.episodeOpen).notify)
    }

    func testCopyNamesTheLaneAndClaimsNoVerdict() {
        for lane in TrainingLaneKind.allCases {
            let copy = Policy.copy(lane)
            XCTAssertFalse(copy.title.isEmpty)
            XCTAssertFalse(copy.body.lowercased().contains("overtrain"))
        }
    }
}
