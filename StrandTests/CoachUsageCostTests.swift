import XCTest
@testable import Strand

/// What a turn cost, in money rather than tokens.
///
/// The interesting cases are all about REFUSING to answer. A cost line is read as authoritative, so a
/// figure that quietly leaves out the cached half of a turn is worse than no figure — these pin that the
/// calculator returns nil in exactly the situations where it cannot be honest, and a number in the ones
/// where the catalogue actually published the rate.
final class CoachUsageCostTests: XCTestCase {

    /// Rates in the shape `/models` publishes them, scaled to USD per 1M tokens by `parseModelDetails`.
    /// These match the Anthropic-family row in the live catalogue: $10 in, $50 out, $1 cache read,
    /// $12.50 cache write.
    private let fullPrices = CoachUsageLog.ModelPrices(promptPerMillion: 10,
                                                      completionPerMillion: 50,
                                                      cacheReadPerMillion: 1,
                                                      cacheWritePerMillion: 12.5)

    private func turn(input: Int = 0, cacheRead: Int = 0,
                      cacheWrite: Int = 0, output: Int = 0) -> CoachUsageLog.Turn {
        CoachUsageLog.Turn(rounds: [CoachUsageLog.Round(inputTokens: input,
                                                        cacheReadTokens: cacheRead,
                                                        cacheWriteTokens: cacheWrite,
                                                        outputTokens: output)])
    }

    func testAPlainTurnIsInputPlusOutput() {
        // 100 000 in at $10/M = $1.00; 20 000 out at $50/M = $1.00.
        let value = CoachUsageLog.cost(for: turn(input: 100_000, output: 20_000), prices: fullPrices)
        XCTAssertEqual(try XCTUnwrap(value), 2.00, accuracy: 0.000_001)
    }

    /// The cached part bills at the PUBLISHED cache rate, not at a fraction of the input rate.
    /// `cacheVerdict`'s "about a tenth of the price" is prose about Anthropic; it is not a rate.
    func testCachedTokensUseTheirOwnPublishedRate() {
        // 50 000 in at $10/M = $0.50; 100 000 cache-read at $1/M = $0.10; 8 000 cache-write at
        // $12.50/M = $0.10; 10 000 out at $50/M = $0.50.
        let value = CoachUsageLog.cost(
            for: turn(input: 50_000, cacheRead: 100_000, cacheWrite: 8_000, output: 10_000),
            prices: fullPrices)
        XCTAssertEqual(try XCTUnwrap(value), 1.20, accuracy: 0.000_001)
    }

    /// The refusal that matters: the model cached, and its catalogue entry says nothing about what a
    /// cached token costs. Pricing those at the full input rate would overstate by 10x on the Anthropic
    /// models measured, and pricing them at zero would understate.
    func testACachedTurnOnAModelWithNoCacheRateHasNoCost() {
        let noCacheRate = CoachUsageLog.ModelPrices(promptPerMillion: 10, completionPerMillion: 50,
                                                    cacheReadPerMillion: nil, cacheWritePerMillion: nil)
        XCTAssertNil(CoachUsageLog.cost(for: turn(input: 100, cacheRead: 5_000), prices: noCacheRate))
        XCTAssertNil(CoachUsageLog.cost(for: turn(input: 100, cacheWrite: 5_000), prices: noCacheRate))

        // …but the same model prices an UNCACHED turn perfectly well: the missing rate only disqualifies
        // the turns that actually used the cache.
        XCTAssertEqual(try XCTUnwrap(CoachUsageLog.cost(for: turn(input: 100_000, output: 20_000),
                                                        prices: noCacheRate)),
                       2.00, accuracy: 0.000_001)
    }

    func testNoPricesMeansNoCostAndNoLine() {
        XCTAssertNil(CoachUsageLog.cost(for: turn(input: 100_000, output: 20_000), prices: nil))
        XCTAssertNil(CoachUsageLog.costLine(for: turn(input: 100_000, output: 20_000), prices: nil))
    }

    /// A free-tier model publishes "0" for both rates, which is an ANSWER — $0.00 — not an absent price.
    /// `tencent/hy3:free` in the frozen `/models` sample is exactly this row.
    func testAFreeModelCostsZeroRatherThanNothingKnown() {
        let free = CoachUsageLog.ModelPrices(promptPerMillion: 0, completionPerMillion: 0,
                                             cacheReadPerMillion: nil, cacheWritePerMillion: nil)
        XCTAssertEqual(try XCTUnwrap(CoachUsageLog.cost(for: turn(input: 100_000, output: 20_000),
                                                        prices: free)),
                       0)
        XCTAssertNotNil(CoachUsageLog.costLine(for: turn(input: 100_000, output: 20_000), prices: free))
    }

    /// A sub-cent turn is the ordinary case on a cheap model. Rounded to two places it would print as
    /// "$0.00" and read as free, so it gets four.
    func testASubCentTurnKeepsEnoughDigitsToNotReadAsFree() {
        let line = try? XCTUnwrap(CoachUsageLog.costLine(for: turn(input: 200, output: 40),
                                                         prices: fullPrices))
        XCTAssertNotNil(line)
        XCTAssertFalse(line?.contains("0.00)") ?? false)
        // 200 × $10/M + 40 × $50/M = $0.004.
        XCTAssertEqual(try XCTUnwrap(CoachUsageLog.cost(for: turn(input: 200, output: 40),
                                                        prices: fullPrices)),
                       0.004, accuracy: 0.000_001)
    }

    /// A multi-round tool answer is one turn: the rounds are summed before the rates are applied, so a
    /// question answered in five rounds reports what it actually cost.
    func testEveryRoundOfATurnIsCounted() {
        let multi = CoachUsageLog.Turn(rounds: [
            CoachUsageLog.Round(inputTokens: 50_000, outputTokens: 10_000),
            CoachUsageLog.Round(inputTokens: 50_000, outputTokens: 10_000)
        ])
        XCTAssertEqual(try XCTUnwrap(CoachUsageLog.cost(for: multi, prices: fullPrices)),
                       2.00, accuracy: 0.000_001)
    }
}
