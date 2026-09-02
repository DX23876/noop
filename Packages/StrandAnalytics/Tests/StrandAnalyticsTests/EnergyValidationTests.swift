import XCTest
@testable import StrandAnalytics

final class EnergyValidationTests: XCTestCase {
    func testRegisteredGateUsesHoldoutAndPassesAppleParity() {
        let contexts: [EnergyContext] = [
            .sedentary, .unresolvedElevatedHR, .locomotion, .confirmedWorkout,
        ]
        var samples: [EnergyValidationSample] = [
            .init(cohort: .development, participantID: "training-only", context: .locomotion,
                  groundTruthKcal: 100, noopKcal: 10_000, appleWatchKcal: 100),
        ]
        for participant in 0..<20 {
            for context in contexts {
                samples.append(.init(
                    cohort: .holdout, participantID: "p\(participant)", context: context,
                    groundTruthKcal: 100, noopKcal: 102, appleWatchKcal: 101,
                    noopIntervalKcal: participant == 0 ? 103...110 : 90...110))
            }
        }

        let report = EnergyValidation.evaluate(samples)
        XCTAssertTrue(report.passedReleaseGate, report.blockingReasons.joined(separator: ", "))
        XCTAssertEqual(report.holdoutSampleCount, 80)
        XCTAssertEqual(report.noop?.participantCount, 20)
        XCTAssertEqual(report.noop?.weightedAbsolutePercentageError ?? 0, 0.02, accuracy: 0.0001)
    }

    func testQuietHighHeartRateFalsePositiveBlocksRelease() {
        var samples: [EnergyValidationSample] = []
        for participant in 0..<20 {
            for context in EnergyValidationPolicy.release.requiredContexts {
                let noop = context == .unresolvedElevatedHR ? 160.0 : 100.0
                samples.append(.init(
                    cohort: .holdout, participantID: "p\(participant)", context: context,
                    groundTruthKcal: 100, noopKcal: noop, appleWatchKcal: 100,
                    noopIntervalKcal: 90...170))
            }
        }

        let report = EnergyValidation.evaluate(samples)
        XCTAssertFalse(report.passedReleaseGate)
        XCTAssertTrue(report.blockingReasons.contains { $0.contains("unresolvedElevatedHR WAPE") })
        XCTAssertTrue(report.blockingReasons.contains { $0.contains("non-inferiority") })
    }

    func testMissingComparatorAndIntervalsCannotPass() {
        let rows = (0..<20).flatMap { participant in
            EnergyValidationPolicy.release.requiredContexts.map { context in
                EnergyValidationSample(cohort: .holdout, participantID: "p\(participant)",
                                       context: context, groundTruthKcal: 100, noopKcal: 100)
            }
        }
        let report = EnergyValidation.evaluate(rows)
        XCTAssertFalse(report.passedReleaseGate)
        XCTAssertTrue(report.blockingReasons.contains { $0.contains("Apple Watch comparator missing") })
        XCTAssertTrue(report.blockingReasons.contains("NOOP uncertainty intervals missing"))
    }
}
