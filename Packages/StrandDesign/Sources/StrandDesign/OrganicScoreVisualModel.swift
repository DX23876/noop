import Foundation

/// The three score families rendered by Liquid Today's organic hero.
public enum OrganicScoreMetric: String, CaseIterable, Equatable, Sendable {
    case charge
    case effort
    case rest
}

/// Renderer-independent visual amplitudes. Every component is normalised to `0...1`, except
/// `echoLevel`, whose integer part is the number of fully visible echo contours and whose fraction is
/// the opacity of the next contour.
public struct OrganicScoreIntensity: Equatable, Sendable {
    public let particleDensity: Double
    public let waveStrength: Double
    public let pulseStrength: Double
    public let glowStrength: Double
    public let smokeStrength: Double
    public let echoLevel: Double

    /// A missing score has a legible contour but no value-implying activity.
    public static let quiet = OrganicScoreIntensity(
        particleDensity: 0,
        waveStrength: 0,
        pulseStrength: 0,
        glowStrength: 0,
        smokeStrength: 0,
        echoLevel: 0
    )

    fileprivate static func interpolated(at value: Double) -> OrganicScoreIntensity {
        let anchors: [(position: Double, intensity: OrganicScoreIntensity)] = [
            (0.00, OrganicScoreIntensity(
                particleDensity: 0.02, waveStrength: 0.03, pulseStrength: 0.02,
                glowStrength: 0.06, smokeStrength: 0.02, echoLevel: 0.10
            )),
            (0.20, OrganicScoreIntensity(
                particleDensity: 0.08, waveStrength: 0.08, pulseStrength: 0.06,
                glowStrength: 0.14, smokeStrength: 0.06, echoLevel: 0.50
            )),
            (0.50, OrganicScoreIntensity(
                particleDensity: 0.24, waveStrength: 0.22, pulseStrength: 0.18,
                glowStrength: 0.30, smokeStrength: 0.18, echoLevel: 1.00
            )),
            (0.80, OrganicScoreIntensity(
                particleDensity: 0.54, waveStrength: 0.48, pulseStrength: 0.44,
                glowStrength: 0.58, smokeStrength: 0.42, echoLevel: 1.60
            )),
            (0.90, OrganicScoreIntensity(
                particleDensity: 0.72, waveStrength: 0.66, pulseStrength: 0.64,
                glowStrength: 0.76, smokeStrength: 0.62, echoLevel: 2.00
            )),
            (1.00, OrganicScoreIntensity(
                particleDensity: 1.00, waveStrength: 1.00, pulseStrength: 1.00,
                glowStrength: 1.00, smokeStrength: 1.00, echoLevel: 3.00
            )),
        ]

        let clamped = min(max(value, 0), 1)
        guard let upperIndex = anchors.firstIndex(where: { $0.position >= clamped }) else {
            return anchors[anchors.count - 1].intensity
        }
        guard upperIndex > 0 else { return anchors[0].intensity }

        let lower = anchors[upperIndex - 1]
        let upper = anchors[upperIndex]
        let span = upper.position - lower.position
        let fraction = span > 0 ? (clamped - lower.position) / span : 0

        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        return OrganicScoreIntensity(
            particleDensity: mix(lower.intensity.particleDensity, upper.intensity.particleDensity),
            waveStrength: mix(lower.intensity.waveStrength, upper.intensity.waveStrength),
            pulseStrength: mix(lower.intensity.pulseStrength, upper.intensity.pulseStrength),
            glowStrength: mix(lower.intensity.glowStrength, upper.intensity.glowStrength),
            smokeStrength: mix(lower.intensity.smokeStrength, upper.intensity.smokeStrength),
            echoLevel: mix(lower.intensity.echoLevel, upper.intensity.echoLevel)
        )
    }
}

/// Pure value-to-visual contract for the organic score renderer.
public struct OrganicScoreVisualModel: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case missing
        case value
    }

    public let metric: OrganicScoreMetric
    public let state: State
    public let normalizedValue: Double?
    public let chargeBand: ChargeBand?
    public let intensity: OrganicScoreIntensity
    public let seed: UInt64

    /// Resolves a displayed score against its displayed maximum. The renderer consumes only this
    /// normalised result, which makes Effort's 0-21 and 0-100 presentation scales visually identical.
    public static func resolve(
        metric: OrganicScoreMetric,
        value: Double?,
        scaleMaximum: Double = 100,
        seedSalt: UInt64 = 0
    ) -> OrganicScoreVisualModel {
        let seed = metric.baseSeed ^ Self.mix(seedSalt)
        guard let value, value.isFinite, scaleMaximum.isFinite, scaleMaximum > 0 else {
            return OrganicScoreVisualModel(
                metric: metric,
                state: .missing,
                normalizedValue: nil,
                chargeBand: nil,
                intensity: .quiet,
                seed: seed
            )
        }

        let normalized = min(max(value / scaleMaximum, 0), 1)
        return OrganicScoreVisualModel(
            metric: metric,
            state: .value,
            normalizedValue: normalized,
            chargeBand: metric == .charge ? ChargeBand.of(score: normalized * 100) : nil,
            intensity: .interpolated(at: normalized),
            seed: seed
        )
    }

    /// A stable pseudo-random word for one particle attribute. Score changes intentionally do not enter
    /// the seed, so particles brighten and fade in place instead of teleporting when the value updates.
    public func particleSeed(index: Int, channel: Int) -> UInt64 {
        let particle = UInt64(bitPattern: Int64(index)) &* 0xD6E8_FEB8_6659_FD93
        let attribute = UInt64(bitPattern: Int64(channel)) &* 0xA076_1D64_78BD_642F
        return Self.mix(seed ^ particle ^ attribute)
    }

    /// The particle seed mapped to the exactly representable `0..<1` range used by Canvas geometry.
    public func particleUnit(index: Int, channel: Int) -> Double {
        Double(particleSeed(index: index, channel: channel) >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Signed radial deformation for the principal contour, expressed as a fraction of the renderer's
    /// maximum deformation. Integer angular frequencies keep the full-circle mean at zero: the ring
    /// breathes in local zones without translating its centre or inflating its average diameter.
    ///
    /// Gated on intensity rather than `state` so a morph out of the missing state (whose intensity is
    /// `.quiet`) grows its waveform continuously instead of switching it on in one frame.
    public func contourOffset(angle: Double, time: Double) -> Double {
        guard intensity.waveStrength > 0 else { return 0 }

        let tau = Double.pi * 2
        let phaseA = particleUnit(index: 0, channel: 10) * tau
        let phaseB = particleUnit(index: 0, channel: 11) * tau
        let phaseC = particleUnit(index: 0, channel: 12) * tau
        let pulsePhase = particleUnit(index: 0, channel: 13) * tau

        // Eight soft lobes carry the shape (the approved reference reads as a rounded eight-point
        // bloom); five and thirteen break its symmetry so no two rings, or two moments, look alike.
        let waveform = (
            sin(angle * 8 + phaseA + time * 0.62)
            + sin(angle * 5 + phaseB - time * 0.47) * 0.38
            + sin(angle * 13 + phaseC + time * 0.36) * 0.22
        ) / 1.60
        let localPulse = 0.72 + 0.28 * intensity.pulseStrength
            * cos(angle * 2 + pulsePhase + time * 0.41)
        // The breath swells the waves, never the ring: amplitude only, so the mean radius stays put.
        let swell = 1 - intensity.pulseStrength * 0.35 * (1 - breath(time: time))
        return (waveform * localPulse * swell * 0.78 + localSwells(angle: angle, time: time))
            * intensity.waveStrength
    }

    /// Small, fine regions of the contour that bulge out (now and then pull in) on their own: each a
    /// narrow bump that wanders slowly round the ring, grows, recedes and resurfaces elsewhere. More
    /// and stronger at higher scores; a low score shows one or two faint ones.
    ///
    /// Each bump is a Gaussian with its own mean AND first circular harmonic subtracted analytically.
    /// Without that, a bump would inflate the mean radius and pull the visual centre toward itself;
    /// with it, the ring keeps its size and centre exactly while the local edge moves.
    private func localSwells(angle: Double, time: Double) -> Double {
        let count = 2 + Int((intensity.pulseStrength * 3).rounded())   // 2 ... 5
        let tau = Double.pi * 2
        var total = 0.0
        for index in 0..<count {
            let u = { (channel: Int) in particleUnit(index: 100 + index, channel: channel) }
            let width = 0.09 + u(30) * 0.10                       // radians: a fine, narrow region
            let drift = (u(31) - 0.5) * 0.24                       // rad/s, either way round
            let centre = u(32) * tau + time * drift
            // Lifecycle: rises, holds briefly, recedes, rests; each bump on its own period and phase.
            let cycle = max(0, sin(time * (0.35 + u(33) * 0.45) + u(34) * tau))
            let sign = u(35) < 0.8 ? 1.0 : -1.0                    // mostly outward, sometimes inward
            let amplitude = sign * (0.18 + u(36) * 0.22) * cycle * cycle
                * (0.5 + 0.5 * intensity.pulseStrength)
            guard amplitude != 0 else { continue }

            var delta = (angle - centre).truncatingRemainder(dividingBy: tau)
            if delta > .pi { delta -= tau } else if delta < -.pi { delta += tau }
            let bump = exp(-(delta * delta) / (2 * width * width))
            let area = width * (2 * Double.pi).squareRoot()      // ∫ bump over the circle
            let mean = area / tau
            let firstHarmonic = area * exp(-width * width / 2) / Double.pi
            total += amplitude * (bump - mean - firstHarmonic * cos(delta))
        }
        return total
    }

    /// A slow, soft breath in `0...1` (about four seconds a cycle, slightly different per metric so the
    /// three rings do not pulse in lockstep). Drives brightness and wave height, never size or position.
    public func breath(time: Double) -> Double {
        let period = 3.6 + particleUnit(index: 0, channel: 14) * 0.9
        let phase = particleUnit(index: 0, channel: 15) * .pi * 2
        let raw = 0.5 + 0.5 * sin(time * .pi * 2 / period + phase)
        return raw * raw * (3 - 2 * raw)   // eased, so it lingers at full and empty like a breath
    }

    /// Brightness multiplier for glow, haze and bloom at `time`: a dim score barely breathes, a full one
    /// breathes visibly.
    public func breathBrightness(time: Double) -> Double {
        1 + intensity.pulseStrength * 0.45 * (breath(time: time) - 0.5) * 2
    }

    /// The model a value change passes through, `fraction` of the way from `self` to `target`.
    ///
    /// Intensity blends component-wise; identity (metric, seed, state, band) is the target's from the
    /// first frame, so the particle field never reshuffles and colour semantics follow the new number.
    public func interpolated(to target: OrganicScoreVisualModel, fraction rawFraction: Double) -> OrganicScoreVisualModel {
        let fraction = min(max(rawFraction, 0), 1)
        guard fraction < 1 else { return target }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        let from = intensity
        let to = target.intensity
        return OrganicScoreVisualModel(
            metric: target.metric,
            state: target.state,
            normalizedValue: target.normalizedValue,
            chargeBand: target.chargeBand,
            intensity: OrganicScoreIntensity(
                particleDensity: mix(from.particleDensity, to.particleDensity),
                waveStrength: mix(from.waveStrength, to.waveStrength),
                pulseStrength: mix(from.pulseStrength, to.pulseStrength),
                glowStrength: mix(from.glowStrength, to.glowStrength),
                smokeStrength: mix(from.smokeStrength, to.smokeStrength),
                echoLevel: mix(from.echoLevel, to.echoLevel)
            ),
            seed: target.seed
        )
    }

    /// SplitMix64's finaliser: fixed-width integer arithmetic, deterministic on every Apple target.
    private static func mix(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private extension OrganicScoreMetric {
    /// ASCII-derived constants keep each metric's particle field distinct without unstable hashing.
    var baseSeed: UInt64 {
        switch self {
        case .charge: return 0x43_48_41_52_47_45
        case .effort: return 0x45_46_46_4F_52_54
        case .rest:   return 0x52_45_53_54
        }
    }
}

// MARK: - Geometry

/// Renderer quality steps. Under frame pressure the renderer gives up smoke, particles and echoes in
/// that order; the number, the principal contour and the hit target never degrade.
public enum OrganicScoreQuality: Int, CaseIterable, Comparable, Sendable {
    case minimal
    case reduced
    case full

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var particleBudget: Int {
        switch self {
        case .full: return 320
        case .reduced: return 180
        case .minimal: return 80
        }
    }

    /// Upper bound on the fine wave filaments that make up the luminous band.
    public var filamentBudget: Int {
        switch self {
        case .full: return 9
        case .reduced: return 6
        case .minimal: return 3
        }
    }

    public var echoLimit: Int {
        switch self {
        case .full: return 3
        case .reduced: return 2
        case .minimal: return 1
        }
    }

    public var drawsSmoke: Bool { self != .minimal }

    public var contourSamples: Int {
        switch self {
        case .full: return 192
        case .reduced: return 132
        case .minimal: return 84
        }
    }
}

/// The physical input one frame of the hero responds to, already in SCREEN space (x right, y down)
/// and smoothed by `OrganicScoreMotionFilter`. `.still` is what every static or opted-out path uses.
public struct OrganicScoreMotionInput: Equatable, Sendable {
    public var gravity: OrganicScoreVector
    public var impulse: OrganicScoreVector

    public init(gravity: OrganicScoreVector, impulse: OrganicScoreVector) {
        self.gravity = gravity
        self.impulse = impulse
    }

    public static let still = OrganicScoreMotionInput(gravity: .zero, impulse: .zero)
}

/// One particle in polar-free form: `x`/`y` are offsets from the ring centre in units of the mean
/// contour radius, `size` is in points at the renderer's reference diameter.
public struct OrganicScoreParticle: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let size: Double
    public let alpha: Double
}

public extension OrganicScoreVisualModel {
    /// Mean contour radius as a fraction of the ring's square frame.
    static let baseRadiusFraction = 0.37
    /// Largest radial deformation, in units of the mean contour radius.
    static let deformationRatio = 0.19
    /// The value's clear zone: an ellipse (semi-axes in units of the mean contour radius), wider than
    /// tall because the number is. No particle is ever placed inside it.
    static let quietCentre = (horizontal: 0.62, vertical: 0.44)
    /// Particles stay this fraction inside the live contour so none can touch or cross it.
    static let particleContainment = 0.93

    /// The contour's radius at `angle`, in units of the mean radius. Motion adds a second-order
    /// (elliptical) squash against the movement; a first-order term would read as the ring sliding,
    /// which the spec forbids, while the second-order one keeps the mean and the centroid fixed.
    func contourRadius(angle: Double, time: Double, motion: OrganicScoreMotionInput = .still) -> Double {
        let wave = contourOffset(angle: angle, time: time)
        let impulse = motion.impulse
        let magnitude = min(impulse.magnitude, 1)
        var squash = 0.0
        if magnitude > 0 {
            let direction = atan2(impulse.y, impulse.x)
            let responsiveness = state == .value ? 1.0 : 0.25
            squash = magnitude * 0.35 * responsiveness * cos(2 * (angle - direction))
        }
        return 1 + Self.deformationRatio * (wave + squash)
    }

    /// Fraction of particles placed inside the circle rather than on the band, by particle density.
    static func interiorShare(_ density: Double) -> Double {
        0.15 + min(max(density, 0), 1) * 0.45
    }

    /// Radius of the value's clear zone at `angle`, in units of the mean contour radius.
    static func quietCentreRadius(angle: Double) -> Double {
        let a = quietCentre.horizontal
        let b = quietCentre.vertical
        let c = cos(angle)
        let s = sin(angle)
        return (a * b) / ((b * c) * (b * c) + (a * s) * (a * s)).squareRoot()
    }

    /// How many particles this value draws at `quality`. Zero for the missing state.
    func particleCount(quality: OrganicScoreQuality) -> Int {
        guard intensity.particleDensity > 0 else { return 0 }
        let budget = quality.particleBudget
        let scaled = 8 + intensity.particleDensity * Double(budget - 8)
        return min(budget, max(8, Int(scaled.rounded())))
    }

    /// Half the luminous band's radial thickness, in units of the mean radius. A low score is a thin
    /// line; a high one a broad band of interleaved filaments.
    var bandHalfWidth: Double {
        0.03 + intensity.glowStrength * 0.16
    }

    /// How many filaments weave the band at `quality`: one for a missing value, up to the budget.
    func filamentCount(quality: OrganicScoreQuality) -> Int {
        guard intensity.waveStrength > 0 else { return 1 }
        let scaled = 2 + intensity.glowStrength * Double(quality.filamentBudget - 2)
        return min(quality.filamentBudget, max(2, Int(scaled.rounded())))
    }

    /// Radius of filament `index` of `count` at `angle`: the contour slightly earlier or later in time,
    /// spread across the band, so the strands cross and separate like the reference's interleaved lines.
    func filamentRadius(index: Int, count: Int, angle: Double, time: Double,
                        motion: OrganicScoreMotionInput = .still) -> Double {
        guard count > 1 else { return contourRadius(angle: angle, time: time, motion: motion) }
        let spread = Double(index) / Double(count - 1) * 2 - 1           // -1 ... 1 across the band
        let lag = (particleUnit(index: index, channel: 20) - 0.5) * 2.4  // seconds, per strand
        let base = contourRadius(angle: angle, time: time + lag, motion: motion)
        // Each strand has its own slow ripple (6 to 11 lobes, own phase and speed), so neighbouring strands
        // cross and part across the band instead of running as parallel copies of one line.
        let lobes = Double(6 + Int(particleUnit(index: index, channel: 22) * 6))
        let phase = particleUnit(index: index, channel: 21) * .pi * 2
        let speed = 0.4 + particleUnit(index: index, channel: 23) * 0.7
        let ripple = sin(angle * lobes + phase + time * speed) * bandHalfWidth * 0.55
        return base + spread * bandHalfWidth * 0.6 + ripple
    }

    /// How many echo contours draw at `quality`, and the opacity of each (`0...1`).
    func echoVisibilities(quality: OrganicScoreQuality) -> [Double] {
        (0..<quality.echoLimit).compactMap { index in
            let visibility = min(1, max(0, intensity.echoLevel - Double(index)))
            return visibility > 0 ? visibility : nil
        }
    }

    /// Radius of echo `index` at `angle`: the contour as it was a moment earlier, pushed outward, and
    /// spaced wider on the side gravity pulls toward. Echoes may lean; the principal contour never does.
    func echoRadius(index: Int, angle: Double, time: Double, motion: OrganicScoreMotionInput = .still) -> Double {
        let lagged = contourRadius(angle: angle, time: time - Double(index + 1) * 0.36, motion: motion)
        let gravity = motion.gravity
        let lean = gravity.x * cos(angle) + gravity.y * sin(angle)
        let spacing = 0.063 * Double(index + 1) * (1 + 0.35 * lean)
        return lagged + spacing
    }

    /// Particle `index` at `time`. Always strictly between the value's clear zone and the live contour;
    /// nil only when the contour has pinched too close to the clear zone to fit one this frame.
    func particle(index: Int, time: Double, motion: OrganicScoreMotionInput = .still) -> OrganicScoreParticle? {
        let tau = Double.pi * 2
        let phase = particleUnit(index: index, channel: 1) * tau
        let speed = 0.12 + particleUnit(index: index, channel: 2) * 0.22
        var angle = particleUnit(index: index, channel: 0) * tau
            + sin(time * speed + phase) * (0.05 + intensity.pulseStrength * 0.06)

        // Slow tilt: each particle leans a little toward where gravity points, by its own amount,
        // so the field settles downhill without moving as one block.
        let gravity = motion.gravity
        let pull = min(gravity.magnitude, 1)
        if pull > 0 {
            let downhill = atan2(gravity.y, gravity.x)
            let personal = 0.06 + particleUnit(index: index, channel: 6) * 0.08
            angle += sin(downhill - angle) * personal * pull
        }

        let inner = Self.quietCentreRadius(angle: angle) + 0.03
        let contour = contourRadius(angle: angle, time: time, motion: motion)
        let lean = pull > 0 ? (gravity.x * cos(angle) + gravity.y * sin(angle)) : 0
        let current = cos(time * 0.22 + phase * 1.7) * 0.07
        let radius: Double
        // A higher score fills the circle: the interior's share rises from ~15 % to ~60 % on top of the
        // overall count rising with the value. A low score keeps its few particles on the band.
        if particleUnit(index: index, channel: 7) >= Self.interiorShare(intensity.particleDensity) {
            // Particles in the luminous band, scattered across its width.
            let band = bandHalfWidth
            let offset = (particleUnit(index: index, channel: 3) * 2 - 1 + current + lean * 0.3) * band
            radius = max(inner, contour + min(max(offset, -band), band) * 0.98)
        } else {
            // The rest drift loosely inside, between the clear zone and the band.
            let outer = (contour - bandHalfWidth) * Self.particleContainment
            guard outer > inner + 0.02 else { return nil }
            let base = particleUnit(index: index, channel: 3).squareRoot()
            let unit = min(max(base + lean * 0.18 + current, 0), 1)
            radius = inner + unit * (outer - inner)
        }
        // Each particle twinkles on its own slow cycle; the field never flashes as one.
        let twinkle = 0.65 + 0.35 * sin(time * (0.6 + particleUnit(index: index, channel: 8)) + phase * 3)

        return OrganicScoreParticle(
            x: cos(angle) * radius,
            y: sin(angle) * radius,
            size: particleUnit(index: index, channel: 9) < 0.08
                ? 1.8 + particleUnit(index: index, channel: 4) * 0.8      // the occasional sparkle
                : 0.5 + particleUnit(index: index, channel: 4) * 0.9,
            alpha: (0.35 + particleUnit(index: index, channel: 5) * 0.6) * twinkle
        )
    }
}

// MARK: - Value morph

/// A ~1 s ease-out between two visual models, evaluated against the hero's render clock. Pure, so the
/// renderer can ask for any frame without owning animation state.
public struct OrganicScoreMorph: Equatable, Sendable {
    public static let duration = 0.95

    public let from: OrganicScoreVisualModel
    public let to: OrganicScoreVisualModel
    public let start: Double

    public init(from: OrganicScoreVisualModel, to: OrganicScoreVisualModel, start: Double) {
        self.from = from
        self.to = to
        self.start = start
    }

    /// A morph that is already finished: what Reduce Motion and the static path use.
    public static func settled(_ model: OrganicScoreVisualModel) -> OrganicScoreMorph {
        OrganicScoreMorph(from: model, to: model, start: -.infinity)
    }

    public func progress(at time: Double) -> Double {
        guard start.isFinite else { return 1 }
        let t = min(max((time - start) / Self.duration, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    public func model(at time: Double) -> OrganicScoreVisualModel {
        from.interpolated(to: to, fraction: progress(at: time))
    }

    /// Retarget toward `target` from wherever this morph is at `time`, so a second update mid-flight
    /// continues smoothly instead of snapping back to the old start.
    public func retargeted(_ target: OrganicScoreVisualModel, at time: Double, animated: Bool) -> OrganicScoreMorph {
        guard animated else { return .settled(target) }
        return OrganicScoreMorph(from: model(at: time), to: target, start: time)
    }
}

// MARK: - Animation gates

/// Every condition that decides whether the hero runs a live frame clock and whether it may read the
/// motion sensor. One pure answer, so a new call site cannot forget a gate.
public struct OrganicScoreAnimationGate: Equatable, Sendable {
    public var dataReady: Bool
    public var reduceMotion: Bool
    public var quietMotion: Bool
    public var lowPower: Bool
    public var windowObscured: Bool
    public var sceneActive: Bool
    public var tabActive: Bool
    public var heroVisible: Bool
    public var reactsToDeviceMovement: Bool
    public var platformHasMotionSensor: Bool

    public init(dataReady: Bool, reduceMotion: Bool, quietMotion: Bool, lowPower: Bool,
                windowObscured: Bool, sceneActive: Bool, tabActive: Bool, heroVisible: Bool,
                reactsToDeviceMovement: Bool, platformHasMotionSensor: Bool) {
        self.dataReady = dataReady
        self.reduceMotion = reduceMotion
        self.quietMotion = quietMotion
        self.lowPower = lowPower
        self.windowObscured = windowObscured
        self.sceneActive = sceneActive
        self.tabActive = tabActive
        self.heroVisible = heroVisible
        self.reactsToDeviceMovement = reactsToDeviceMovement
        self.platformHasMotionSensor = platformHasMotionSensor
    }

    /// The autonomous breathing clock. The movement preference does not enter: it only removes the
    /// phone's influence, never the rings' own life.
    public var runsFrameClock: Bool {
        dataReady && !reduceMotion && !quietMotion && !lowPower && !windowObscured
            && sceneActive && tabActive && heroVisible
    }

    /// Whether the hero holds the shared motion sensor this frame.
    public var readsMotionSensor: Bool {
        runsFrameClock && reactsToDeviceMovement && platformHasMotionSensor
    }
}

/// The display-only preference behind "React to device movement". Default on.
public enum OrganicScoreMotionPrefs {
    public static let reactsToMovementKey = "noop.liquidHeroReactsToMovement"
    public static let reactsToMovementDefault = true
}
