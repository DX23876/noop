import XCTest
@testable import Strand

/// Pins the cache keys the steps-motion cache is addressed by.
///
/// They are a storage contract, not a naming choice: every install's cached volumes live under these
/// strings, so changing one silently re-reads sixty days of gravity per pass on every device until the
/// cache refills — the precise 28.93 s cost the cache exists to remove, reintroduced invisibly.
final class StepsMotionCacheKeyTests: XCTestCase {

    func testKeysAreStableAndDistinct() {
        XCTAssertEqual(IntelligenceEngine.stepsMotionKey, "steps_motion")
        XCTAssertEqual(IntelligenceEngine.stepsMotionInputRevKey, "steps_motion_input_rev")
        XCTAssertEqual(IntelligenceEngine.stepsMotionDeviceRevKey, "steps_motion_device_rev")
        XCTAssertEqual(Set([IntelligenceEngine.stepsMotionKey,
                            IntelligenceEngine.stepsMotionInputRevKey,
                            IntelligenceEngine.stepsMotionDeviceRevKey]).count, 3)
    }

    /// Distinct from the estimate the same block writes under the same device id — one series overwriting
    /// the other would feed motion volumes to the steps tile as if they were step counts.
    func testKeysDoNotCollideWithTheStepsEstimateSeries() {
        for key in [IntelligenceEngine.stepsMotionKey,
                    IntelligenceEngine.stepsMotionInputRevKey,
                    IntelligenceEngine.stepsMotionDeviceRevKey] {
            XCTAssertNotEqual(key, "steps_est")
            XCTAssertNotEqual(key, "steps")
        }
    }
}
