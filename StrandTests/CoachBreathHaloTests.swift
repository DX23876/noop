import XCTest
import SwiftUI
import StrandDesign
@testable import Strand

/// The Coach entry's breathing corona — the geometry half, which is pure and therefore checkable
/// without a renderer. The gate around it (the user's setting AND the motion state) is bound to
/// SwiftUI state and is verified in the simulator instead.
///
/// Why a corona at all: the breath used to live on a 104pt tile where a 3% scale swell was plainly
/// visible. The entry is now a 30pt header button, and 3% of 30pt is 0.9pt — a pulse nobody would ever
/// notice. A ring that swells carries the signal at a size where movement cannot.
final class CoachBreathHaloTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testTheHaloStaysInsideItsFrame() {
        let path = SpikedHaloShape().path(in: rect)
        XCTAssertFalse(path.isEmpty)
        // A spike poking outside the frame would lap over the neighbouring header control, which sits
        // only 8pt away — it must stay within the bounds it is handed.
        XCTAssertTrue(rect.insetBy(dx: -0.001, dy: -0.001).contains(path.boundingRect),
                      "the corona escaped its frame: \(path.boundingRect)")
    }

    /// The tips must actually reach the edge — a corona inset from its own frame would read as a
    /// smaller disc rather than as spikes around the avatar.
    func testTheSpikeTipsReachTheEdge() {
        let bounds = SpikedHaloShape().path(in: rect).boundingRect
        XCTAssertEqual(bounds.width, rect.width, accuracy: 0.5)
        XCTAssertEqual(bounds.height, rect.height, accuracy: 0.5)
    }

    func testMoreSpikesMeansMorePathElements() {
        func elementCount(_ shape: SpikedHaloShape) -> Int {
            var n = 0
            shape.path(in: rect).forEach { _ in n += 1 }
            return n
        }
        XCTAssertGreaterThan(elementCount(SpikedHaloShape(spikes: 32)),
                             elementCount(SpikedHaloShape(spikes: 8)))
    }

    /// Degenerate inputs must produce nothing, not NaN geometry or a crash: a view can be laid out at
    /// zero size before its frame resolves, and a ratio of 1 collapses the spikes onto the circle.
    func testDegenerateInputsProduceAnEmptyOrPlainPath() {
        XCTAssertTrue(SpikedHaloShape().path(in: .zero).isEmpty)
        XCTAssertTrue(SpikedHaloShape(spikes: 0).path(in: rect).isEmpty)
        XCTAssertTrue(SpikedHaloShape(spikes: 2).path(in: rect).isEmpty,
                      "fewer than three points cannot enclose an area")
        let flat = SpikedHaloShape(innerRatio: 1).path(in: rect)
        XCTAssertFalse(flat.isEmpty, "ratio 1 is a plain circle, not an error")
        XCTAssertTrue(rect.insetBy(dx: -0.001, dy: -0.001).contains(flat.boundingRect))
    }

    /// An out-of-range ratio is clamped rather than inverting the shape.
    func testRatioIsClamped() {
        let negative = SpikedHaloShape(innerRatio: -3).path(in: rect)
        XCTAssertTrue(rect.insetBy(dx: -0.001, dy: -0.001).contains(negative.boundingRect))
    }

    // MARK: - The gate both entry points share

    /// The setting alone is not enough: a system-level request for less movement outranks it.
    @MainActor
    func testMotionStateVetoesTheUserSetting() {
        let motion = NoopMotionState.shared
        XCTAssertFalse(CoachBreath.isActive(reduceMotion: true, enabled: true, motion: motion),
                       "Reduce Motion must stop the breath even when the switch is on")
        XCTAssertFalse(CoachBreath.isActive(reduceMotion: false, enabled: false, motion: motion),
                       "the switch off must stop it regardless of motion state")
    }
}
