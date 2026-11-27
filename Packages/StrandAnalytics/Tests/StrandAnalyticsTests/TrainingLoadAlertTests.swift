import XCTest
@testable import StrandAnalytics

/// The Training Load alert posts once per high phase and never while off.
final class TrainingLoadAlertTests: XCTestCase {
    func testOneAlertPerHighPhase() {
        var open = false
        var posted = 0
        for band: RelativeLoadBand? in [.usual, .higher, .muchHigher, .muchHigher, .muchHigher, .higher,
                                        .muchHigher, nil, .muchHigher] {
            let decision = TrainingLoadAlert.decide(enabled: true, band: band, episodeOpen: open)
            if decision.notify { posted += 1 }
            open = decision.episodeOpen
        }
        XCTAssertEqual(posted, 3, "three separate entries into well above usual, each posted once")
    }

    /// Off means silent, and the phase is still tracked, so switching on mid-phase does not post for a week
    /// already under way.
    func testOffIsSilentAndKeepsTrackOfThePhase() {
        let off = TrainingLoadAlert.decide(enabled: false, band: .muchHigher, episodeOpen: false)
        XCTAssertFalse(off.notify)
        XCTAssertTrue(off.episodeOpen)
        XCTAssertFalse(TrainingLoadAlert.decide(enabled: true, band: .muchHigher, episodeOpen: off.episodeOpen).notify)
    }

    func testAnyOtherBandClosesTheEpisode() {
        for band: RelativeLoadBand? in [nil, .below, .usual, .higher] {
            let decision = TrainingLoadAlert.decide(enabled: true, band: band, episodeOpen: true)
            XCTAssertFalse(decision.notify)
            XCTAssertFalse(decision.episodeOpen)
        }
    }
}
