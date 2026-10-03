import XCTest
import SwiftUI
@testable import StrandDesign

final class AdaptiveHeaderLayoutTests: XCTestCase {
    func testExpandedSyncAndControlCountsFitPhoneWidths() {
        for width in [CGFloat(288), 320, 343, 361, 370, 398] {
            for count in [5, 6] {
                for syncWidth in [CGFloat(46), 98, 118] {
                    var controls = Array(repeating: CGSize(width: 46, height: 46), count: count)
                    controls[2].width = syncWidth
                    let result = AdaptiveHeaderLayout.arrange(
                        title: CGSize(width: 85, height: 60), controls: controls,
                        width: width, spacing: NoopMetrics.space1)
                    XCTAssertEqual(result.size.width, width)
                    for frame in result.frames {
                        XCTAssertGreaterThanOrEqual(frame.minX, 0)
                        XCTAssertLessThanOrEqual(frame.maxX, width)
                        XCTAssertLessThanOrEqual(frame.maxY, result.size.height)
                    }
                    for (index, frame) in result.frames.enumerated() {
                        for other in result.frames.dropFirst(index + 1) {
                            XCTAssertFalse(frame.intersects(other), "title and controls must not overlap")
                        }
                    }
                }
            }
        }
    }

    func testWideHeaderKeepsControlsBesideTitle() {
        let result = AdaptiveHeaderLayout.arrange(
            title: CGSize(width: 140, height: 60),
            controls: Array(repeating: CGSize(width: 46, height: 46), count: 6),
            width: 800, spacing: NoopMetrics.space3)
        XCTAssertTrue(result.frames.allSatisfy { $0.minY == 0 })
        XCTAssertEqual(result.size.height, 60)
    }

    func testStackedHeaderGivesTheTitleItsOwnRowEvenWhenItWouldFit() {
        let result = AdaptiveHeaderLayout.arrange(
            title: CGSize(width: 140, height: 60),
            controls: Array(repeating: CGSize(width: 46, height: 46), count: 5),
            width: 800, spacing: NoopMetrics.space1, stacked: true)
        XCTAssertEqual(result.frames[0].minY, 0)
        XCTAssertTrue(result.frames.dropFirst().allSatisfy { $0.minY >= result.frames[0].maxY })
        XCTAssertTrue(result.frames.allSatisfy { $0.maxX <= 800 })
    }
}
