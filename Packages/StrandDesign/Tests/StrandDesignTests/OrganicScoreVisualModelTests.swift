import XCTest
@testable import StrandDesign

final class OrganicScoreVisualModelTests: XCTestCase {
    func testMissingValueProducesAQuietNeutralState() {
        let model = OrganicScoreVisualModel.resolve(metric: .charge, value: nil)

        XCTAssertEqual(model.state, .missing)
        XCTAssertNil(model.normalizedValue)
        XCTAssertNil(model.chargeBand)
        XCTAssertEqual(model.intensity, .quiet)
    }

    func testInvalidNumbersProduceAQuietNeutralState() {
        let invalidScale = OrganicScoreVisualModel.resolve(
            metric: .effort,
            value: 12,
            scaleMaximum: 0
        )
        let invalidValue = OrganicScoreVisualModel.resolve(
            metric: .rest,
            value: .infinity
        )

        for model in [invalidScale, invalidValue] {
            XCTAssertEqual(model.state, .missing)
            XCTAssertNil(model.normalizedValue)
            XCTAssertNil(model.chargeBand)
            XCTAssertEqual(model.intensity, .quiet)
        }
    }

    func testValuesClampToTheScoreRange() {
        let below = OrganicScoreVisualModel.resolve(metric: .rest, value: -12)
        let above = OrganicScoreVisualModel.resolve(metric: .rest, value: 140)

        XCTAssertEqual(below.normalizedValue, 0)
        XCTAssertEqual(above.normalizedValue, 1)
    }

    func testVisualIntensityRisesAcrossEveryApprovedAnchor() {
        let anchors = [0.0, 20, 50, 80, 90, 100].map {
            OrganicScoreVisualModel.resolve(metric: .rest, value: $0).intensity
        }

        for (lower, higher) in zip(anchors, anchors.dropFirst()) {
            XCTAssertGreaterThan(higher.particleDensity, lower.particleDensity)
            XCTAssertGreaterThan(higher.waveStrength, lower.waveStrength)
            XCTAssertGreaterThan(higher.pulseStrength, lower.pulseStrength)
            XCTAssertGreaterThan(higher.glowStrength, lower.glowStrength)
            XCTAssertGreaterThan(higher.smokeStrength, lower.smokeStrength)
            XCTAssertGreaterThan(higher.echoLevel, lower.echoLevel)
        }
    }

    func testParticleSeedsAreRepeatableAndMetricSpecific() {
        let first = OrganicScoreVisualModel.resolve(metric: .charge, value: 94, seedSalt: 42)
        let repeated = OrganicScoreVisualModel.resolve(metric: .charge, value: 12, seedSalt: 42)
        let otherMetric = OrganicScoreVisualModel.resolve(metric: .rest, value: 94, seedSalt: 42)

        let sample = first.particleSeed(index: 7, channel: 2)
        XCTAssertEqual(sample, 6_575_077_328_993_530_808,
                       "the persisted particle field must not change between releases")
        XCTAssertEqual(sample, repeated.particleSeed(index: 7, channel: 2),
                       "score changes must not reshuffle the particle field")
        XCTAssertNotEqual(sample, first.particleSeed(index: 8, channel: 2))
        XCTAssertNotEqual(sample, first.particleSeed(index: 7, channel: 3))
        XCTAssertNotEqual(sample, otherMetric.particleSeed(index: 7, channel: 2))
        XCTAssertTrue((0..<1).contains(first.particleUnit(index: 7, channel: 2)))
    }

    func testEffortPresentationScalesResolveToTheSameVisualState() {
        let hundred = OrganicScoreVisualModel.resolve(metric: .effort, value: 40, scaleMaximum: 100)
        let whoop = OrganicScoreVisualModel.resolve(metric: .effort, value: 8.4, scaleMaximum: 21)

        XCTAssertEqual(hundred.normalizedValue, whoop.normalizedValue)
        XCTAssertEqual(hundred.intensity, whoop.intensity)
        XCTAssertEqual(hundred.seed, whoop.seed)
    }

    func testFinalDecileIsANonlinearVisualPeak() {
        let eighty = OrganicScoreVisualModel.resolve(metric: .rest, value: 80).intensity
        let ninety = OrganicScoreVisualModel.resolve(metric: .rest, value: 90).intensity
        let hundred = OrganicScoreVisualModel.resolve(metric: .rest, value: 100).intensity

        XCTAssertGreaterThan(hundred.particleDensity - ninety.particleDensity,
                             ninety.particleDensity - eighty.particleDensity)
        XCTAssertGreaterThan(hundred.waveStrength - ninety.waveStrength,
                             ninety.waveStrength - eighty.waveStrength)
        XCTAssertGreaterThan(hundred.pulseStrength - ninety.pulseStrength,
                             ninety.pulseStrength - eighty.pulseStrength)
        XCTAssertGreaterThan(hundred.echoLevel - ninety.echoLevel,
                             ninety.echoLevel - eighty.echoLevel)

        let eightyTwo = OrganicScoreVisualModel.resolve(metric: .rest, value: 82).intensity
        let ninetyFour = OrganicScoreVisualModel.resolve(metric: .rest, value: 94).intensity
        XCTAssertGreaterThan(ninetyFour.particleDensity - eightyTwo.particleDensity, 0.20)
        XCTAssertGreaterThan(ninetyFour.waveStrength - eightyTwo.waveStrength, 0.20)
        XCTAssertGreaterThan(ninetyFour.echoLevel - eightyTwo.echoLevel, 0.50)
    }

    func testChargeUsesTheCanonicalRecoveryBands() {
        XCTAssertEqual(OrganicScoreVisualModel.resolve(metric: .charge, value: 12).chargeBand, .depleted)
        XCTAssertEqual(OrganicScoreVisualModel.resolve(metric: .charge, value: 38).chargeBand, .low)
        XCTAssertEqual(OrganicScoreVisualModel.resolve(metric: .charge, value: 62).chargeBand, .moderate)
        XCTAssertEqual(OrganicScoreVisualModel.resolve(metric: .charge, value: 79).chargeBand, .primed)
        XCTAssertEqual(OrganicScoreVisualModel.resolve(metric: .charge, value: 94).chargeBand, .peak)

        XCTAssertNil(OrganicScoreVisualModel.resolve(metric: .effort, value: 94).chargeBand)
        XCTAssertNil(OrganicScoreVisualModel.resolve(metric: .rest, value: 94).chargeBand)
    }

    func testContourDeformsWithoutTranslatingOrInflatingItsMeanRadius() {
        let model = OrganicScoreVisualModel.resolve(metric: .rest, value: 94, seedSalt: 7)
        let samples = (0..<720).map { index in
            model.contourOffset(
                angle: Double(index) / 720 * .pi * 2,
                time: 18.25
            )
        }

        XCTAssertEqual(samples.reduce(0, +) / Double(samples.count), 0, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, model.intensity.waveStrength)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.2)
    }

    func testContourNoiseIsStableDephasedAndQuietWhenMissing() {
        let charge = OrganicScoreVisualModel.resolve(metric: .charge, value: 82, seedSalt: 4)
        let chargeAgain = OrganicScoreVisualModel.resolve(metric: .charge, value: 82, seedSalt: 4)
        let rest = OrganicScoreVisualModel.resolve(metric: .rest, value: 82, seedSalt: 4)
        let missing = OrganicScoreVisualModel.resolve(metric: .charge, value: nil, seedSalt: 4)

        XCTAssertEqual(charge.contourOffset(angle: 1.2, time: 3.4),
                       chargeAgain.contourOffset(angle: 1.2, time: 3.4))
        XCTAssertNotEqual(charge.contourOffset(angle: 1.2, time: 3.4),
                          rest.contourOffset(angle: 1.2, time: 3.4))
        XCTAssertEqual(missing.contourOffset(angle: 1.2, time: 3.4), 0)
    }
}
