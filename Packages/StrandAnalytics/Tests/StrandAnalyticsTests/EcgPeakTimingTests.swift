import XCTest
@testable import StrandAnalytics

final class EcgPeakTimingTests: XCTestCase {
    func testConstantOffGridIntervalsDoNotManufactureHRV() throws {
        let generator = EcgAnalysisTests()
        for rr in [613.0, 777, 923, 1107] {
            for sign in [-1.0, 1.0] {
                let samples = generator.strip(seconds: 40,
                    rTimesMs: generator.regular(rrMs: rr, seconds: 40), noise: 0, sign: sign)
                let result = try XCTUnwrap(EcgAnalysis.analyze(samples))
                XCTAssertEqual(result.meanHeartRate, 60_000 / rr, accuracy: 0.1)
                XCTAssertLessThan(try XCTUnwrap(result.rmssdMs), 2.5, "rr=\(rr), sign=\(sign)")
                XCTAssertLessThan(try XCTUnwrap(result.sdnnMs), 1.5, "rr=\(rr), sign=\(sign)")
            }
        }
    }

    func testSmallAndLargeInjectedVariabilityIsRecoveredOffGrid() throws {
        let generator = EcgAnalysisTests()
        for delta in [5.0, 17, 43, 61] {
            var times: [Double] = []
            var time = 405.0
            while time < 39_400 {
                times.append(time)
                time += 773 + (times.count.isMultiple(of: 2) ? delta : 0)
            }
            for sign in [-1.0, 1.0] {
                let result = try XCTUnwrap(EcgAnalysis.analyze(
                    generator.strip(seconds: 40, rTimesMs: times, noise: 0, sign: sign)))
                XCTAssertEqual(try XCTUnwrap(result.rmssdMs), delta, accuracy: 2)
                XCTAssertEqual(result.irregularBeats, 0)
            }
        }
    }
    func testParabolicVertexTracksPositionScaleAndOffset() {
        for position in [-0.49, -0.31, 0.0, 0.23, 0.49] {
            for scale in [1.0, 100, 12000] {
                for dc in [-300.0, 0, 4000] {
                    func value(_ x: Double) -> Double { dc - scale * pow(x - position, 2) }
                    XCTAssertEqual(EcgAnalysis.peakOffset(left: value(-1), center: value(0), right: value(1)),
                                   position, accuracy: 1e-9)
                }
            }
        }
    }

    func testInvalidOrFlatTripletsRetainTheirSamplePosition() {
        for (left, center, right) in [(0.0, 0.0, 0.0), (1, 0, 1), (2, 1, 0),
                                      (.nan, 1, 0), (0, .infinity, 0), (0, 1, -.infinity)] {
            XCTAssertEqual(EcgAnalysis.peakOffset(left: left, center: center, right: right), 0)
        }
        XCTAssertEqual(EcgAnalysis.peakOffset(left: 10, center: 10, right: 0), -0.5)
        XCTAssertEqual(EcgAnalysis.peakOffset(left: 0, center: 10, right: 10), 0.5)
    }

    func testChangingRateAcrossAGapDoesNotCreateSuccessiveDifferences() throws {
        let generator = EcgAnalysisTests()
        for (before, after) in [(643.0, 883.0), (773.0, 1107.0), (947.0, 733.0)] {
            let times = Array(stride(from: 405.0, to: 18000.0, by: before))
                + Array(stride(from: 21403.0, to: 39400.0, by: after))
            let samples = generator.strip(seconds: 40, rTimesMs: times, noise: 0, gap: 1800..<2100)
            let result = try XCTUnwrap(EcgAnalysis.analyze(samples))
            XCTAssertLessThan(try XCTUnwrap(result.rmssdMs), 2.5)
        }
    }

    func testPeakWidthAmplitudeAndSmallNoiseDoNotRestoreGridArtifact() throws {
        let generator = EcgAnalysisTests()
        for width in [8.0, 12, 18] {
            for amplitude in [400.0, 900, 1800] {
                var beat = EcgAnalysisTests.Beat()
                beat.r.sigmaMs = width
                let factor = amplitude / 900
                beat.p.microvolts *= factor; beat.q.microvolts *= factor
                beat.r.microvolts *= factor; beat.s.microvolts *= factor; beat.t.microvolts *= factor
                let result = try XCTUnwrap(EcgAnalysis.analyze(generator.strip(seconds: 40,
                    rTimesMs: generator.regular(rrMs: 773, seconds: 40), beat: beat, noise: 12)))
                XCTAssertLessThan(try XCTUnwrap(result.rmssdMs), 3,
                                  "width=\(width), amplitude=\(amplitude)")
            }
        }
    }

}
