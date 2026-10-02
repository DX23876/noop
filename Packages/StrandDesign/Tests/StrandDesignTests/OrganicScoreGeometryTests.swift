import XCTest
@testable import StrandDesign

final class OrganicScoreGeometryTests: XCTestCase {
    private let motions: [OrganicScoreMotionInput] = [
        .still,
        OrganicScoreMotionInput(gravity: OrganicScoreVector(x: 0, y: 1), impulse: .zero),
        OrganicScoreMotionInput(gravity: OrganicScoreVector(x: -0.7, y: 0.7),
                                impulse: OrganicScoreVector(x: 1, y: 0)),
    ]

    func testParticlesStayBetweenTheQuietCentreAndTheLiveContour() {
        var drawn = 0
        for value in [20.0, 50, 80, 90, 94, 100] {
            let model = OrganicScoreVisualModel.resolve(metric: .charge, value: value)
            for motion in motions {
                for time in stride(from: 0.0, through: 240, by: 7.3) {
                    for index in 0..<model.particleCount(quality: .full) {
                        guard let particle = model.particle(index: index, time: time, motion: motion) else { continue }
                        drawn += 1
                        let angle = atan2(particle.y, particle.x)
                        let radius = hypot(particle.x, particle.y)
                        XCTAssertGreaterThan(radius, OrganicScoreVisualModel.quietCentreRadius(angle: angle),
                                             "a particle entered the value's clear zone")
                        XCTAssertLessThan(radius, model.contourRadius(angle: angle, time: time, motion: motion)
                                              + model.bandHalfWidth,
                                          "a particle escaped the luminous band")
                    }
                }
            }
        }
        XCTAssertGreaterThan(drawn, 10_000)
    }

    func testBandAndFilamentsGrowWithTheValue() {
        let values = [20.0, 50, 80, 94, 100].map { OrganicScoreVisualModel.resolve(metric: .rest, value: $0) }
        for (lower, higher) in zip(values, values.dropFirst()) {
            XCTAssertGreaterThan(higher.bandHalfWidth, lower.bandHalfWidth)
            XCTAssertGreaterThanOrEqual(higher.filamentCount(quality: .full), lower.filamentCount(quality: .full))
        }
        XCTAssertEqual(values.last?.filamentCount(quality: .full), OrganicScoreQuality.full.filamentBudget)
        XCTAssertEqual(OrganicScoreVisualModel.resolve(metric: .rest, value: nil).filamentCount(quality: .full), 1)
    }

    func testHigherValuesPutMoreParticlesInsideTheCircle() {
        func interiorCount(_ value: Double) -> Int {
            let model = OrganicScoreVisualModel.resolve(metric: .charge, value: value)
            return (0..<model.particleCount(quality: .full)).compactMap { model.particle(index: $0, time: 12) }
                .filter { p in
                    let angle = atan2(p.y, p.x)
                    return hypot(p.x, p.y) < model.contourRadius(angle: angle, time: 12) - model.bandHalfWidth
                }.count
        }
        XCTAssertLessThan(interiorCount(20), interiorCount(50))
        XCTAssertLessThan(interiorCount(50), interiorCount(94))
        XCTAssertGreaterThan(Double(interiorCount(100)), 100, "a full score fills the circle")
    }

    func testBreathIsBoundedDephasedAndStrongerForHighScores() {
        let high = OrganicScoreVisualModel.resolve(metric: .rest, value: 95)
        let low = OrganicScoreVisualModel.resolve(metric: .rest, value: 15)
        let charge = OrganicScoreVisualModel.resolve(metric: .charge, value: 95)
        var highRange = (min: 9.0, max: -9.0), lowRange = (min: 9.0, max: -9.0)
        var differs = false
        for step in 0..<400 {
            let t = Double(step) * 0.05
            let b = high.breath(time: t)
            XCTAssertTrue((0...1).contains(b))
            highRange = (min(highRange.min, high.breathBrightness(time: t)), max(highRange.max, high.breathBrightness(time: t)))
            lowRange = (min(lowRange.min, low.breathBrightness(time: t)), max(lowRange.max, low.breathBrightness(time: t)))
            if abs(b - charge.breath(time: t)) > 0.2 { differs = true }
        }
        XCTAssertGreaterThan(highRange.max - highRange.min, 0.6, "a full score breathes visibly")
        XCTAssertLessThan(lowRange.max - lowRange.min, highRange.max - highRange.min)
        XCTAssertTrue(differs, "the rings do not breathe in lockstep")
    }

    func testQuietCentreClearsTheValueBox() {
        // The number is wider than tall: the zone must reach further sideways than vertically.
        XCTAssertEqual(OrganicScoreVisualModel.quietCentreRadius(angle: 0), 0.62, accuracy: 1e-9)
        XCTAssertEqual(OrganicScoreVisualModel.quietCentreRadius(angle: .pi / 2), 0.44, accuracy: 1e-9)
    }

    func testMissingStateDrawsNoParticlesOrEchoes() {
        let missing = OrganicScoreVisualModel.resolve(metric: .rest, value: nil)
        for quality in OrganicScoreQuality.allCases {
            XCTAssertEqual(missing.particleCount(quality: quality), 0)
            XCTAssertTrue(missing.echoVisibilities(quality: quality).isEmpty)
        }
    }

    func testQualityDropsDetailButNeverTheContour() {
        let model = OrganicScoreVisualModel.resolve(metric: .effort, value: 100)
        let ordered = OrganicScoreQuality.allCases.sorted()
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(model.particleCount(quality: lower), model.particleCount(quality: higher))
            XCTAssertLessThanOrEqual(model.echoVisibilities(quality: lower).count,
                                     model.echoVisibilities(quality: higher).count)
            XCTAssertLessThan(lower.contourSamples, higher.contourSamples)
        }
        XCTAssertEqual(model.echoVisibilities(quality: .full).count, 3)
        XCTAssertFalse(OrganicScoreQuality.minimal.drawsSmoke)
    }

    func testMotionSquashKeepsMeanRadiusAndCentroid() {
        let model = OrganicScoreVisualModel.resolve(metric: .rest, value: 60)
        let motion = OrganicScoreMotionInput(gravity: OrganicScoreVector(x: 0.4, y: 0.9),
                                             impulse: OrganicScoreVector(x: 0.6, y: -0.8))
        let samples = 1440
        var sum = 0.0, cx = 0.0, cy = 0.0
        for index in 0..<samples {
            let angle = Double(index) / Double(samples) * .pi * 2
            let still = model.contourRadius(angle: angle, time: 9, motion: .still)
            let moved = model.contourRadius(angle: angle, time: 9, motion: motion)
            let delta = moved - still
            sum += delta
            cx += delta * cos(angle)
            cy += delta * sin(angle)
        }
        XCTAssertEqual(sum / Double(samples), 0, accuracy: 1e-9, "movement must not inflate the ring")
        XCTAssertEqual(cx / Double(samples), 0, accuracy: 1e-9, "movement must not slide the ring")
        XCTAssertEqual(cy / Double(samples), 0, accuracy: 1e-9, "movement must not slide the ring")
    }

    func testAllRingsLeanTheSameWayUnderOneGravity() {
        // Shared direction: with gravity pointing down the screen, every metric's particles drift down.
        let motion = OrganicScoreMotionInput(gravity: OrganicScoreVector(x: 0, y: 1), impulse: .zero)
        for metric in OrganicScoreMetric.allCases {
            let model = OrganicScoreVisualModel.resolve(metric: metric, value: 80)
            var still = 0.0, tilted = 0.0
            for index in 0..<model.particleCount(quality: .full) {
                if let p = model.particle(index: index, time: 30, motion: .still) { still += p.y }
                if let p = model.particle(index: index, time: 30, motion: motion) { tilted += p.y }
            }
            XCTAssertGreaterThan(tilted, still, "\(metric) did not settle toward gravity")
        }
    }

    func testMorphEasesOverAboutOneSecondAndRetargetsSmoothly() {
        let low = OrganicScoreVisualModel.resolve(metric: .charge, value: 20)
        let high = OrganicScoreVisualModel.resolve(metric: .charge, value: 94)
        let morph = OrganicScoreMorph(from: low, to: high, start: 100)

        XCTAssertEqual(morph.model(at: 100).intensity, low.intensity)
        XCTAssertEqual(morph.model(at: 101).intensity, high.intensity)
        let mid = morph.model(at: 100.4).intensity.particleDensity
        XCTAssertGreaterThan(mid, low.intensity.particleDensity)
        XCTAssertLessThan(mid, high.intensity.particleDensity)
        XCTAssertEqual(morph.model(at: 100.4).chargeBand, .peak, "colour semantics follow the new value at once")

        let retarget = morph.retargeted(low, at: 100.4, animated: true)
        XCTAssertEqual(retarget.model(at: 100.4).intensity.particleDensity, mid, accuracy: 1e-12)

        let reduced = morph.retargeted(low, at: 100.4, animated: false)
        XCTAssertEqual(reduced.model(at: 100.4), low, "Reduce Motion shows the new state immediately")
    }

    func testMorphOutOfMissingGrowsContinuously() {
        let missing = OrganicScoreVisualModel.resolve(metric: .rest, value: nil)
        let value = OrganicScoreVisualModel.resolve(metric: .rest, value: 70)
        let early = OrganicScoreMorph(from: missing, to: value, start: 0).model(at: 0.05)
        XCTAssertLessThan(early.intensity.waveStrength, value.intensity.waveStrength * 0.3)
        XCTAssertGreaterThan(early.intensity.waveStrength, 0)
    }

    func testEveryStaticGateStopsTheClockAndTheSensor() {
        let live = OrganicScoreAnimationGate(
            dataReady: true, reduceMotion: false, quietMotion: false, lowPower: false,
            windowObscured: false, sceneActive: true, tabActive: true, heroVisible: true,
            reactsToDeviceMovement: true, platformHasMotionSensor: true
        )
        XCTAssertTrue(live.runsFrameClock)
        XCTAssertTrue(live.readsMotionSensor)

        let stoppers: [WritableKeyPath<OrganicScoreAnimationGate, Bool>: Bool] = [
            \.dataReady: false, \.reduceMotion: true, \.quietMotion: true, \.lowPower: true,
            \.windowObscured: true, \.sceneActive: false, \.tabActive: false, \.heroVisible: false,
        ]
        for (path, value) in stoppers {
            var gate = live
            gate[keyPath: path] = value
            XCTAssertFalse(gate.runsFrameClock, "\(path) must stop the frame clock")
            XCTAssertFalse(gate.readsMotionSensor, "\(path) must release the sensor")
        }
    }

    func testMovementPreferenceKeepsBreathingButDropsTheSensor() {
        var gate = OrganicScoreAnimationGate(
            dataReady: true, reduceMotion: false, quietMotion: false, lowPower: false,
            windowObscured: false, sceneActive: true, tabActive: true, heroVisible: true,
            reactsToDeviceMovement: false, platformHasMotionSensor: true
        )
        XCTAssertTrue(gate.runsFrameClock)
        XCTAssertFalse(gate.readsMotionSensor)

        gate.reactsToDeviceMovement = true
        gate.platformHasMotionSensor = false   // macOS
        XCTAssertTrue(gate.runsFrameClock)
        XCTAssertFalse(gate.readsMotionSensor)
        XCTAssertTrue(OrganicScoreMotionPrefs.reactsToMovementDefault)
    }
}
