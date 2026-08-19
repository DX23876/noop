import XCTest

@testable import Strand

/// `CoachSemanticTelemetry` is a pure value type, so the counters and the percentile are pinned here without a
/// coach engine, a model or an index.
final class CoachSemanticTelemetryTests: XCTestCase {

    func testNothingMeasuredYetReportsNoRowAtAll() {
        let telemetry = CoachSemanticTelemetry()
        XCTAssertNil(telemetry.semanticWinRate)
        XCTAssertNil(telemetry.summary, "an empty row is worse than no row")
    }

    /// The rate that decides whether latency work comes before ranking work.
    func testWinRateCountsOnlyTurnsWhereRetrievalWasAttempted() {
        var telemetry = CoachSemanticTelemetry()
        telemetry.record(mode: .semantic)
        telemetry.record(mode: .semantic)
        telemetry.record(mode: .keywordFallback)
        XCTAssertEqual(telemetry.semanticWinRate!, 2.0 / 3, accuracy: 1e-9)
    }

    /// `unavailable` means nothing matched or the feature is off. Folding it into either column would make the
    /// win rate depend on how many questions happened to have no answer, which is not what it is measuring.
    func testUnavailableTurnsAreNeitherAWinNorAFallback() {
        var telemetry = CoachSemanticTelemetry()
        telemetry.record(mode: .semantic)
        telemetry.record(mode: .unavailable)
        XCTAssertEqual(telemetry.attemptedTurns, 1)
        XCTAssertEqual(telemetry.semanticWinRate!, 1, accuracy: 1e-9)
        XCTAssertEqual(telemetry.unavailableTurns, 1)
    }

    func testPercentileIsNearestRankOverTheRetainedSamples() {
        var telemetry = CoachSemanticTelemetry()
        for value in [100.0, 200, 300, 400, 500] { telemetry.recordQueryEmbed(milliseconds: value) }
        XCTAssertEqual(telemetry.queryEmbedPercentile(0.5)!, 300, accuracy: 1e-9)
        XCTAssertEqual(telemetry.queryEmbedPercentile(0)!, 100, accuracy: 1e-9)
        XCTAssertEqual(telemetry.queryEmbedPercentile(1)!, 500, accuracy: 1e-9)
    }

    func testPercentileOfNoSamplesIsNil() {
        XCTAssertNil(CoachSemanticTelemetry().queryEmbedPercentile(0.5))
    }

    /// A long session must not grow the sample array without limit — this is held in memory for the life of
    /// the process.
    func testSamplesAreBoundedAndKeepTheMostRecent() {
        var telemetry = CoachSemanticTelemetry()
        for index in 0..<(CoachSemanticTelemetry.sampleLimit + 50) {
            telemetry.recordQueryEmbed(milliseconds: Double(index))
        }
        XCTAssertEqual(telemetry.queryEmbedMilliseconds.count, CoachSemanticTelemetry.sampleLimit)
        XCTAssertEqual(telemetry.queryEmbedMilliseconds.last!,
                       Double(CoachSemanticTelemetry.sampleLimit + 49),
                       accuracy: 1e-9)
    }

    /// A clock that goes backwards, or a NaN out of a failed measurement, must not poison the percentile.
    func testNonFiniteAndNegativeSamplesAreIgnored() {
        var telemetry = CoachSemanticTelemetry()
        telemetry.recordQueryEmbed(milliseconds: .nan)
        telemetry.recordQueryEmbed(milliseconds: -5)
        telemetry.recordModelLoad(milliseconds: .infinity)
        XCTAssertTrue(telemetry.queryEmbedMilliseconds.isEmpty)
        XCTAssertNil(telemetry.modelLoadMilliseconds)
    }

    func testSummaryNamesTheWinRateAndTheLatencies() throws {
        var telemetry = CoachSemanticTelemetry()
        telemetry.record(mode: .semantic)
        telemetry.record(mode: .keywordFallback)
        telemetry.recordQueryEmbed(milliseconds: 400)
        telemetry.recordModelLoad(milliseconds: 1_200)
        let summary = try XCTUnwrap(telemetry.summary)
        XCTAssertTrue(summary.contains("1/2"))
        XCTAssertTrue(summary.contains("50%"))
        XCTAssertTrue(summary.contains("400 ms"))
        XCTAssertTrue(summary.contains("1200 ms"))
    }
}
