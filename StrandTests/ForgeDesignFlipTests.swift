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

    // MARK: Retiring the old design (owner, 2026-11-20)

    /// The case `flipOnce` deliberately left alone: an "off" set after 18 November was a decision, and it
    /// survived. There is nothing to decide any more, so this one clears it too.
    func testRetiringReachesAnOffChosenAfterTheFlip() {
        ForgeDesignPrefs.flipOnce(defaults)
        defaults.set(false, forKey: ForgeDesignPrefs.previewKey)
        XCTAssertFalse(ForgeDesignPrefs.isEnabled(defaults))
        ForgeDesignPrefs.retireTheOldDesign(defaults)
        XCTAssertTrue(ForgeDesignPrefs.isEnabled(defaults))
    }

    /// Its own marker, or the clear would run at every launch and the DEBUG launch override would be the
    /// only way to see anything else ever again.
    func testRetiringRunsOnce() {
        XCTAssertFalse(defaults.bool(forKey: ForgeDesignPrefs.retiredKey))
        ForgeDesignPrefs.retireTheOldDesign(defaults)
        XCTAssertTrue(defaults.bool(forKey: ForgeDesignPrefs.retiredKey))
        defaults.set(false, forKey: ForgeDesignPrefs.previewKey)
        ForgeDesignPrefs.retireTheOldDesign(defaults)
        XCTAssertFalse(ForgeDesignPrefs.isEnabled(defaults),
                       "a second run would make the stored value unusable for anything, tests included")
    }
}
