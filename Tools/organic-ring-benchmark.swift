import Foundation

// Standalone geometry benchmark; Canvas, GPU effects and SwiftUI updates are excluded.
// Compile alongside ChargeBand.swift, OrganicScoreMotion.swift, OrganicScoreVisualModel.swift and
// OrganicScorePreparation.swift using swiftc -O, then run the resulting executable.
// The package's localized ChargeBand labels are unused in this standalone executable.
extension Bundle { static var module: Bundle { .main } }

@main
struct OrganicRingBenchmark {
    static func main() {
        for score in [20.0, 94, 100] {
            let models = OrganicScoreMetric.allCases.map { OrganicScoreVisualModel.resolve(metric: $0, value: score) }
            let preparations = models.map { OrganicScorePreparation(model: $0) }
            let motion = OrganicScoreMotionInput(gravity: .init(x: 0.3, y: -0.5), impulse: .init(x: 0.1, y: 0.2))
            func run(prepared: Bool, samples: Int) -> (seconds: Double, checksum: Double) {
                var checksum = 0.0
                let start = ProcessInfo.processInfo.systemUptime
                for step in 0..<180 {
                    let time = Double(step) / 60
                    for (modelIndex, model) in models.enumerated() {
                        let count = model.filamentCount(quality: .full)
                        let echoCount = model.echoVisibilities(quality: .full).count
                        let frame = prepared ? preparations[modelIndex].frame(model: model, time: time, motion: motion) : nil
                        let filaments = frame.map { frame in (0..<count).map { frame.filamentFrame(index: $0) } } ?? []
                        let echoes = frame.map { frame in (0..<echoCount).map { frame.echoFrame(index: $0) } } ?? []
                        for index in 0..<samples {
                            let angle = Double(index) / Double(samples) * .pi * 2
                            if let frame {
                                checksum += frame.contourRadius(angle: angle)
                                for i in 0..<count {
                                    checksum += frame.filamentRadius(index: i, count: count, angle: angle, base: filaments[i])
                                }
                                for i in 0..<echoCount { checksum += echoes[i].echoRadius(index: i, angle: angle) }
                            } else {
                                checksum += model.contourRadius(angle: angle, time: time, motion: motion)
                                for i in 0..<count {
                                    checksum += model.filamentRadius(index: i, count: count, angle: angle, time: time, motion: motion)
                                }
                                for i in 0..<echoCount {
                                    checksum += model.echoRadius(index: i, angle: angle, time: time, motion: motion)
                                }
                            }
                        }
                        for index in 0..<model.particleCount(quality: .full) {
                            let particle = prepared ? frame!.particle(index: index)
                                : model.particle(index: index, time: time, motion: motion)
                            if let particle { checksum += particle.x + particle.y + particle.alpha }
                        }
                    }
                }
                return (ProcessInfo.processInfo.systemUptime - start, checksum)
            }
            // Warm both paths, then interleave five runs to limit thermal/order bias.
            _ = run(prepared: false, samples: 192)
            _ = run(prepared: true, samples: OrganicScoreQuality.full.contourSamples)
            var original: [Double] = [], prepared: [Double] = [], refined: [Double] = []
            for _ in 0..<5 {
                let old = run(prepared: false, samples: 192)
                let same = run(prepared: true, samples: 192)
                precondition(abs(old.checksum - same.checksum) < 1e-6, "geometry changed")
                original.append(old.seconds)
                prepared.append(same.seconds)
                refined.append(run(prepared: true, samples: OrganicScoreQuality.full.contourSamples).seconds)
            }
            let old = original.sorted()[2], same = prepared.sorted()[2], fine = refined.sorted()[2]
            print(String(format: "score=%.0f original192=%.4fs prepared192=%.4fs prepared%d=%.4fs same_detail_saving=%.1f%% finer_detail_saving=%.1f%%",
                         score, old, same, OrganicScoreQuality.full.contourSamples, fine,
                         (1 - same / old) * 100, (1 - fine / old) * 100))
        }
    }
}
