import Foundation

/// Immutable seed-dependent geometry shared by every frame of one ring. Values and motion remain
/// live; only the fixed particle field and contour parameters are prepared ahead of rendering.
public struct OrganicScorePreparation: Sendable {
    public let seed: UInt64
    private let phases: [Double]
    private let breathPeriod: Double
    private let breathPhase: Double
    private let swells: [Swell]
    private let filaments: [Filament]
    private let particles: [Particle]

    private struct Swell: Sendable {
        let width, drift, centre, frequency, phase, amplitude, mean, harmonic: Double
    }
    private struct Filament: Sendable {
        let lag, lobes, phase, speed: Double
    }
    private struct Particle: Sendable {
        let angle, phase, speed, pull, placement, offset, interior, frequency, size, alpha: Double
    }

    public init(model: OrganicScoreVisualModel) {
        seed = model.seed
        let tau = Double.pi * 2
        phases = (10...13).map { model.particleUnit(index: 0, channel: $0) * tau }
        breathPeriod = 3.6 + model.particleUnit(index: 0, channel: 14) * 0.9
        breathPhase = model.particleUnit(index: 0, channel: 15) * .pi * 2
        swells = (0..<5).map { index in
            let u = { model.particleUnit(index: 100 + index, channel: $0) }
            let width = 0.09 + u(30) * 0.10
            let area = width * (2 * Double.pi).squareRoot()
            let sign = u(35) < 0.8 ? 1.0 : -1.0
            return Swell(width: width, drift: (u(31) - 0.5) * 0.24, centre: u(32) * tau,
                         frequency: 0.35 + u(33) * 0.45, phase: u(34) * tau,
                         amplitude: sign * (0.18 + u(36) * 0.22), mean: area / tau,
                         harmonic: area * exp(-width * width / 2) / Double.pi)
        }
        filaments = (0..<OrganicScoreQuality.full.filamentBudget).map { index in
            Filament(lag: (model.particleUnit(index: index, channel: 20) - 0.5) * 2.4,
                     lobes: Double(6 + Int(model.particleUnit(index: index, channel: 22) * 6)),
                     phase: model.particleUnit(index: index, channel: 21) * .pi * 2,
                     speed: 0.4 + model.particleUnit(index: index, channel: 23) * 0.7)
        }
        particles = (0..<OrganicScoreQuality.full.particleBudget).map { index in
            let u = { model.particleUnit(index: index, channel: $0) }
            return Particle(angle: u(0) * tau, phase: u(1) * tau, speed: 0.12 + u(2) * 0.22,
                            pull: 0.18 + u(6) * 0.22, placement: u(7), offset: u(3) * 2 - 1,
                            interior: u(3).squareRoot(), frequency: 0.6 + u(8),
                            size: u(9) < 0.08 ? 1.8 + u(4) * 0.8 : 0.5 + u(4) * 0.9,
                            alpha: 0.35 + u(5) * 0.6)
        }
    }

    /// Hoists time-, intensity- and motion-dependent work out of the contour-point loops.
    public func frame(model: OrganicScoreVisualModel, time: Double,
                      motion: OrganicScoreMotionInput = .still) -> Frame {
        precondition(seed == model.seed)
        return Frame(preparation: self, model: model, time: time, motion: motion)
    }

    public struct Frame: Sendable {
        private let preparation: OrganicScorePreparation
        private let model: OrganicScoreVisualModel
        private let time: Double
        private let motion: OrganicScoreMotionInput
        private let swell: Double
        private let activeSwells: [ActiveSwell]
        private let impulseMagnitude, impulseDirection, pull, downhill: Double
        public let brightness: Double

        private struct ActiveSwell: Sendable {
            let centre, amplitude, width, mean, harmonic: Double
        }

        fileprivate init(preparation: OrganicScorePreparation, model: OrganicScoreVisualModel,
                         time: Double, motion: OrganicScoreMotionInput) {
            self.preparation = preparation
            self.model = model
            self.time = time
            self.motion = motion
            let raw = 0.5 + 0.5 * sin(time * .pi * 2 / preparation.breathPeriod + preparation.breathPhase)
            let breath = raw * raw * (3 - 2 * raw)
            swell = 1 - model.intensity.pulseStrength * 0.18 * (1 - breath)
            brightness = 1 + model.intensity.pulseStrength * (0.22 + model.effortLoad * 0.1)
                * (breath - 0.5) * 2
            let count = model.intensity.waveStrength > 0
                ? 2 + Int((model.intensity.pulseStrength * 3).rounded()) : 0
            activeSwells = preparation.swells.prefix(count).compactMap { s in
                let cycle = max(0, sin(time * s.frequency + s.phase))
                let amplitude = s.amplitude * cycle * cycle * (0.5 + 0.5 * model.intensity.pulseStrength)
                guard amplitude != 0 else { return nil }
                return ActiveSwell(centre: s.centre + time * s.drift, amplitude: amplitude,
                                   width: s.width, mean: s.mean, harmonic: s.harmonic)
            }
            impulseMagnitude = min(motion.impulse.magnitude, 1)
            impulseDirection = impulseMagnitude > 0 ? atan2(motion.impulse.y, motion.impulse.x) : 0
            pull = min(motion.gravity.magnitude, 1)
            downhill = pull > 0 ? atan2(motion.gravity.y, motion.gravity.x) : 0
        }

        public func contourRadius(angle: Double) -> Double {
            let wave: Double
            if model.intensity.waveStrength > 0 {
                let p = preparation.phases
                let waveform = (sin(angle * 8 + p[0] + time * 0.62)
                    + sin(angle * 5 + p[1] - time * 0.47) * 0.38
                    + sin(angle * 13 + p[2] + time * 0.36) * 0.22) / 1.60
                let localPulse = 0.72 + 0.28 * model.intensity.pulseStrength
                    * cos(angle * 2 + p[3] + time * 0.41)
                let tau = Double.pi * 2
                var total = 0.0
                for s in activeSwells {
                    var delta = (angle - s.centre).truncatingRemainder(dividingBy: tau)
                    if delta > .pi { delta -= tau } else if delta < -.pi { delta += tau }
                    let bump = exp(-(delta * delta) / (2 * s.width * s.width))
                    total += s.amplitude * (bump - s.mean - s.harmonic * cos(delta))
                }
                wave = (waveform * localPulse * swell * 0.78 + total) * model.intensity.waveStrength
            } else {
                wave = 0
            }
            var squash = 0.0
            if impulseMagnitude > 0 {
                let responsiveness = model.state == .value ? 1.0 : 0.25
                squash = impulseMagnitude * 0.6 * responsiveness * cos(2 * (angle - impulseDirection))
            }
            return 1 + OrganicScoreVisualModel.deformationRatio * (wave + squash)
        }

        /// Evaluates an echo on its lagged `echoFrame(index:)`, adding only its spatial offset.
        public func echoRadius(index: Int, angle: Double) -> Double {
            let gravity = motion.gravity
            let lean = gravity.x * cos(angle) + gravity.y * sin(angle)
            return contourRadius(angle: angle) + 0.063 * Double(index + 1) * (1 + 0.9 * lean)
        }

        /// A filament/echo owns one prepared contour at its lagged time, not one per sampled point.
        public func filamentFrame(index: Int) -> Frame {
            preparation.frame(model: model, time: time + preparation.filaments[index].lag, motion: motion)
        }

        public func echoFrame(index: Int) -> Frame {
            preparation.frame(model: model, time: time - Double(index + 1) * 0.36, motion: motion)
        }

        public func filamentRadius(index: Int, count: Int, angle: Double, base: Frame) -> Double {
            guard count > 1 else { return contourRadius(angle: angle) }
            let f = preparation.filaments[index]
            let spread = Double(index) / Double(count - 1) * 2 - 1
            let ripple = sin(angle * f.lobes + f.phase + time * f.speed) * model.bandHalfWidth * 0.55
            return base.contourRadius(angle: angle) + spread * model.bandHalfWidth * 0.6 + ripple
        }

        public func particle(index: Int) -> OrganicScoreParticle? {
            let p = preparation.particles[index]
            var angle = p.angle + sin(time * p.speed + p.phase) * (0.05 + model.intensity.pulseStrength * 0.06)
            if pull > 0 { angle += sin(downhill - angle) * p.pull * pull }
            let inner = OrganicScoreVisualModel.quietCentreRadius(angle: angle) + 0.03
            let contour = contourRadius(angle: angle)
            let gravity = motion.gravity
            let lean = pull > 0 ? (gravity.x * cos(angle) + gravity.y * sin(angle)) : 0
            let current = cos(time * 0.22 + p.phase * 1.7) * 0.07
            let radius: Double
            if p.placement >= OrganicScoreVisualModel.interiorShare(model.intensity.particleDensity) {
                let band = model.bandHalfWidth
                let offset = (p.offset + current + lean * 0.3) * band
                radius = max(inner, contour + min(max(offset, -band), band) * 0.98)
            } else {
                let outer = (contour - model.bandHalfWidth) * OrganicScoreVisualModel.particleContainment
                guard outer > inner + 0.02 else { return nil }
                let unit = min(max(p.interior + lean * 0.18 + current, 0), 1)
                radius = inner + unit * (outer - inner)
            }
            let twinkle = 0.65 + 0.35 * sin(time * p.frequency + p.phase * 3)
            return OrganicScoreParticle(x: cos(angle) * radius, y: sin(angle) * radius,
                                        size: p.size, alpha: p.alpha * twinkle)
        }
    }
}
