import XCTest
@testable import StrandAnalytics

final class HRVCleanProvenanceTests: XCTestCase {
    func testOriginalIndicesTrackRepeatedValuesAndVaryingOutliers() {
        for base in [650.0, 900.0, 1200.0] {
            var input = Array(repeating: base, count: 30)
            input[7] = 200
            input[12] = 2200
            input[20] = base * 1.4
            let clean = HRVAnalyzer.cleanRRGapAware(input)
            let expected = input.indices.filter { ![7, 12, 20].contains($0) }
            XCTAssertEqual(clean.originalIndices, expected)
            XCTAssertEqual(clean.nn, expected.map { input[$0] })
            XCTAssertEqual(clean.nn, HRVAnalyzer.cleanRR(input))
            for i in clean.nn.indices {
                XCTAssertEqual(clean.contiguous[i], i > 0 && expected[i] == expected[i - 1] + 1)
            }
            XCTAssertEqual(HRVAnalyzer.analyze(rawRR: input).rmssd, 0)
        }
    }

    func testShortAndEmptySeriesRetainActualProvenanceWhenAnalysisIsNil() {
        for input in [[], [800], [800, 2200, 800], [200, 800, 850]] as [[Double]] {
            let clean = HRVAnalyzer.cleanRRGapAware(input)
            XCTAssertEqual(clean.nn, clean.originalIndices.map { input[$0] })
            XCTAssertNil(HRVAnalyzer.analyze(rawRR: input).rmssd)
        }
    }
    func testSmallTimingErrorsAreNotMistakenForOutlierRejection() {
        // A 20% local-median rule cannot validate millisecond accuracy against ECG.
        for error in [10.0, 30.0, 80.0] {
            var values = Array(repeating: 900.0, count: 30)
            values[15] += error
            let clean = HRVAnalyzer.cleanRRGapAware(values)
            XCTAssertEqual(clean.originalIndices, Array(values.indices))
            XCTAssertEqual(HRVAnalyzer.analyze(rawRR: values).rmssd!,
                           sqrt(2 * error * error / 29), accuracy: 1e-10)
        }
    }

}
