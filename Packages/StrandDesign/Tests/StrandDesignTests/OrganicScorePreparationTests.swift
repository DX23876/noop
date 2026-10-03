import XCTest
@testable import StrandDesign

final class OrganicScorePreparationTests: XCTestCase {
    func testFinerContoursReduceApproximationErrorWithoutChangingRadius() {
        var oldError = 0.0
        var newError = 0.0
        for metric in OrganicScoreMetric.allCases {
            let model = OrganicScoreVisualModel.resolve(metric: metric, value: 94)
            let preparation = OrganicScorePreparation(model: model)
            for time in [0.0, 3.4, 18.25] {
                let frame = preparation.frame(model: model, time: time)
                func error(samples: Int) -> Double {
                    let tau = Double.pi * 2
                    var total = 0.0
                    for i in 0..<1_440 {
                        let angle = Double(i) / 1_440 * tau
                        let position = angle / tau * Double(samples)
                        let lower = position.rounded(.down)
                        let fraction = position - lower
                        let a = lower / Double(samples) * tau
                        let b = (lower + 1) / Double(samples) * tau
                        let ra = frame.contourRadius(angle: a)
                        let rb = frame.contourRadius(angle: b)
                        let x = cos(a) * ra + (cos(b) * rb - cos(a) * ra) * fraction
                        let y = sin(a) * ra + (sin(b) * rb - sin(a) * ra) * fraction
                        let r = model.contourRadius(angle: angle, time: time)
                        total += hypot(x - cos(angle) * r, y - sin(angle) * r)
                    }
                    return total
                }
                oldError += error(samples: 192)
                newError += error(samples: OrganicScoreQuality.full.contourSamples)
            }
        }
        XCTAssertLessThan(newError, oldError * 0.7)
    }

    func testPreparedGeometryMatchesExistingRendererAcrossValuesMotionAndMorphs() {
        let motions: [OrganicScoreMotionInput] = [
            .still,
            .init(gravity: .init(x: 0.3, y: -0.5), impulse: .init(x: -0.2, y: 0.1)),
            .init(gravity: .init(x: -1, y: 1), impulse: .init(x: 2, y: -3))
        ]
        for metric in OrganicScoreMetric.allCases {
            for salt: UInt64 in [0, 42] {
                let missing = OrganicScoreVisualModel.resolve(metric: metric, value: nil, seedSalt: salt)
                let high = OrganicScoreVisualModel.resolve(metric: metric, value: 94, seedSalt: salt)
                let preparation = OrganicScorePreparation(model: missing)
                let models = [missing, high, missing.interpolated(to: high, fraction: 0.37)]
                    + [0.0, 20, 50, 80, 90, 100].map {
                        OrganicScoreVisualModel.resolve(metric: metric, value: $0, seedSalt: salt)
                    }
                for model in models {
                    for motion in motions {
                        for time in [0.0, 3.4, 18.25, 123_456.789] {
                            let frame = preparation.frame(model: model, time: time, motion: motion)
                            XCTAssertEqual(frame.brightness, model.breathBrightness(time: time), accuracy: 1e-12)
                            for quality in [OrganicScoreQuality.minimal, .reduced, .full] {
                                let count = model.filamentCount(quality: quality)
                                let filaments = (0..<count).map { frame.filamentFrame(index: $0) }
                                let echoes = model.echoVisibilities(quality: quality).indices.map { frame.echoFrame(index: $0) }
                                for index in stride(from: 0, to: quality.contourSamples, by: 13) {
                                    let angle = Double(index) / Double(quality.contourSamples) * .pi * 2
                                    XCTAssertEqual(frame.contourRadius(angle: angle),
                                                   model.contourRadius(angle: angle, time: time, motion: motion), accuracy: 1e-12)
                                    for i in filaments.indices {
                                        XCTAssertEqual(frame.filamentRadius(index: i, count: count, angle: angle, base: filaments[i]),
                                                       model.filamentRadius(index: i, count: count, angle: angle, time: time, motion: motion), accuracy: 1e-12)
                                    }
                                    for i in echoes.indices {
                                        XCTAssertEqual(echoes[i].echoRadius(index: i, angle: angle),
                                                       model.echoRadius(index: i, angle: angle, time: time, motion: motion), accuracy: 1e-12)
                                    }
                                }
                                for index in 0..<model.particleCount(quality: quality) {
                                    let actual = frame.particle(index: index)
                                    let expected = model.particle(index: index, time: time, motion: motion)
                                    XCTAssertEqual(actual == nil, expected == nil)
                                    if let actual, let expected {
                                        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-12)
                                        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-12)
                                        XCTAssertEqual(actual.size, expected.size)
                                        XCTAssertEqual(actual.alpha, expected.alpha, accuracy: 1e-12)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
