import XCTest
@testable import Strand

/// The one-time switch to the new design (owner, 2026-11-18). The twin of Android's `ForgeDesignTest`.
///
/// The case worth a test is the one a plain default flip silently misses: `isEnabled` reads "the stored
/// value, else the default", so an install that had the preview deliberately OFF would keep the old design
/// and report on a screen nobody else is looking at.
final class ForgeDesignFlipTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        // Its own suite: the flip writes, and a test must neither inherit nor leave a marker.
        defaults = UserDefaults(suiteName: "forge-flip-\(UUID().uuidString)")!
    }

    func testTheFlipReachesAnInstallThatHadItOff() {
        defaults.set(false, forKey: ForgeDesignPrefs.previewKey)
        ForgeDesignPrefs.flipOnce(defaults)
        XCTAssertTrue(ForgeDesignPrefs.isEnabled(defaults))
    }

    /// Without the marker the clear would run at every launch and nobody could ever leave the new design.
    func testAnOffChosenAfterTheFlipSurvives() {
        ForgeDesignPrefs.flipOnce(defaults)
        defaults.set(false, forKey: ForgeDesignPrefs.previewKey)
        ForgeDesignPrefs.flipOnce(defaults)
        XCTAssertFalse(ForgeDesignPrefs.isEnabled(defaults))
    }

    func testTheFlipIsMarkedAndTheDefaultIsNowOn() {
        XCTAssertTrue(ForgeDesignPrefs.defaultPreview)
        XCTAssertFalse(defaults.bool(forKey: ForgeDesignPrefs.flippedKey))
        ForgeDesignPrefs.flipOnce(defaults)
        XCTAssertTrue(defaults.bool(forKey: ForgeDesignPrefs.flippedKey))
    }

    /// A fresh install has nothing stored and no marker: it lands on the new design through the default,
    /// and the flip has nothing to carry over.
    func testAFreshInstallIsOnTheNewDesign() {
        XCTAssertTrue(ForgeDesignPrefs.isEnabled(defaults))
        ForgeDesignPrefs.flipOnce(defaults)
        XCTAssertTrue(ForgeDesignPrefs.isEnabled(defaults))
    }
}
