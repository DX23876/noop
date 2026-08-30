import XCTest
import WhoopProtocol
@testable import Strand

/// `Repository.bucketStepMovement` — the pure half of the per-5-minute movement channel that feeds
/// `WhoopEnergyModel`. Split out of the store-bound reader precisely so these rules are testable.
final class EnergyStepBucketTests: XCTestCase {

    private func sample(_ ts: Int, _ counter: Int, _ cls: Int? = nil) -> StepSample {
        StepSample(ts: ts, counter: counter, activityClass: cls)
    }

    /// The reason the lookback exists: without a predecessor, `stepsInWindow` cannot form a delta for
    /// the first sample of a bucket, and the ticks that accrued across every boundary are dropped —
    /// 288 small losses a day, all in the same direction.
    func testBoundaryDeltaIsNotLostBetweenAdjacentBuckets() throws {
        // Bucket A: 0…299, bucket B: 300…599. 100 ticks accrue across the A→B boundary.
        let samples = [sample(290, 1_000), sample(305, 1_100), sample(590, 1_150)]
        let out = Repository.bucketStepMovement(samples, ticksPerStep: 1.0)
        // B must see the 100 across the boundary plus the 50 within it.
        XCTAssertEqual(try XCTUnwrap(out[300]?.steps), 150)
    }

    /// The bug this guards: `@57` is CUMULATIVE, so a predecessor from before a data gap carries
    /// every tick of that gap. `StepsCounter` accepts any delta below 512, so crediting it to the
    /// first bucket after the gap renders hours of absence as minutes of brisk walking.
    func testTicksAccruedAcrossADataGapAreNotCreditedToTheBucketAfterIt() throws {
        let beforeGap = sample(10_000, 1_000)
        let afterGap = sample(10_000 + 7_200, 1_400)      // two hours later, +400 ticks
        let sameBucket = sample(10_000 + 7_260, 1_405)    // +5 genuinely in that bucket
        let out = Repository.bucketStepMovement([beforeGap, afterGap, sameBucket], ticksPerStep: 1.0)

        let gapBucket = (afterGap.ts / 300) * 300
        XCTAssertEqual(try XCTUnwrap(out[gapBucket]?.steps), 5,
                       "only the ticks that accrued INSIDE the bucket may be credited to it")
    }

    /// A predecessor one bucket back is a normal boundary and must still be carried.
    func testPredecessorExactlyOneBucketBackIsStillAccepted() throws {
        // Bucket starting 600; predecessor at 300 is exactly `start - bucketSeconds`.
        let samples = [sample(300, 1_000), sample(605, 1_040)]
        let out = Repository.bucketStepMovement(samples, ticksPerStep: 1.0)
        XCTAssertEqual(try XCTUnwrap(out[600]?.steps), 40)
    }

    /// `stepTicksPerStep` (#139) converts motion TICKS to steps; skipping it feeds the MET model an
    /// inflated cadence on a 5/MG, over-counting exactly where the counter is worst.
    func testTickCalibrationIsApplied() throws {
        let samples = [sample(0, 1_000), sample(60, 1_200)]
        let raw = Repository.bucketStepMovement(samples, ticksPerStep: 1.0)
        let halved = Repository.bucketStepMovement(samples, ticksPerStep: 2.0)
        XCTAssertEqual(try XCTUnwrap(raw[0]?.steps), 200)
        XCTAssertEqual(try XCTUnwrap(halved[0]?.steps), 100)
        // A nonsense calibration must not be able to multiply the count without bound.
        let clamped = Repository.bucketStepMovement(samples, ticksPerStep: 0.01)
        XCTAssertEqual(try XCTUnwrap(clamped[0]?.steps), 400)
    }

    /// Ties resolve DOWN: one stray "run" tick in a bucket of walking must not promote the whole five
    /// minutes to a 7-MET floor.
    func testModalActivityClassResolvesTiesToTheCalmerClass() throws {
        let samples = [sample(0, 1_000, 1), sample(30, 1_010, 1),
                       sample(60, 1_020, 2), sample(90, 1_030, 2)]
        let out = Repository.bucketStepMovement(samples, ticksPerStep: 1.0)
        XCTAssertEqual(try XCTUnwrap(out[0]?.activityClass), 1)
    }

    func testModalActivityClassPrefersTheMajorityClass() throws {
        let samples = [sample(0, 1_000, 1), sample(30, 1_010, 2),
                       sample(60, 1_020, 2), sample(90, 1_030, 2)]
        let out = Repository.bucketStepMovement(samples, ticksPerStep: 1.0)
        XCTAssertEqual(try XCTUnwrap(out[0]?.activityClass), 2)
    }

    /// A stalled counter is not movement — a zero delta must read as "no steps", never as 0 steps
    /// that a caller might treat as a measured value.
    func testStalledCounterYieldsNoStepsRatherThanZero() throws {
        let samples = [sample(0, 1_000), sample(60, 1_000), sample(120, 1_000)]
        let out = Repository.bucketStepMovement(samples, ticksPerStep: 1.0)
        XCTAssertNil(try XCTUnwrap(out[0]).steps)
    }

    func testFewerThanTwoSamplesProduceNothing() {
        XCTAssertTrue(Repository.bucketStepMovement([], ticksPerStep: 1.0).isEmpty)
        XCTAssertTrue(Repository.bucketStepMovement([sample(0, 1_000)], ticksPerStep: 1.0).isEmpty)
    }
}

/// Pins the composition semantics of the Today energy mark. The ring is a breakdown of the energy
/// already shown, never progress toward an invented calorie goal.
final class EnergyCompositionMarkTests: XCTestCase {

    func testRestingAndActiveAreNormalizedIntoOneComposition() throws {
        let fractions = try XCTUnwrap(EnergyCompositionMark.fractions(resting: 750, active: 250))
        XCTAssertEqual(fractions.resting, 0.75, accuracy: 0.0001)
        XCTAssertEqual(fractions.active, 0.25, accuracy: 0.0001)
    }

    func testMissingComponentDoesNotInventEnergy() throws {
        let restingOnly = try XCTUnwrap(EnergyCompositionMark.fractions(resting: 500, active: nil))
        XCTAssertEqual(restingOnly.resting, 1, accuracy: 0.0001)
        XCTAssertEqual(restingOnly.active, 0, accuracy: 0.0001)
    }

    func testMissingOrNonPositiveValuesProduceNoComposition() {
        XCTAssertNil(EnergyCompositionMark.fractions(resting: nil, active: nil))
        XCTAssertNil(EnergyCompositionMark.fractions(resting: -100, active: 0))
    }
}
