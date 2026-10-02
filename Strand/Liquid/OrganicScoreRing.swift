import SwiftUI
import StrandDesign

/// One frame of the organic hero: the shared render time, whether it is live, the device-motion input
/// every ring sees, and the quality step the frame budget allows.
struct OrganicScoreFrame {
    let time: Double
    let isAnimating: Bool
    let motion: OrganicScoreMotionInput
    let quality: OrganicScoreQuality

    static let still = OrganicScoreFrame(time: 0, isAnimating: false, motion: .still, quality: .full)
}

/// Steps quality down when frames arrive late and back up after a long healthy stretch. A reference
/// type because the timeline closure records into it during body evaluation, which `@State` forbids.
private final class OrganicScoreFrameGovernor {
    private(set) var quality: OrganicScoreQuality = .full
    private var lastTime: Double?
    private var average = 1.0 / 60.0
    private var slowFrames = 0
    private var healthyFrames = 0

    func record(_ time: Double) -> OrganicScoreQuality {
        defer { lastTime = time }
        guard let lastTime else { return quality }
        let interval = time - lastTime
        // A gap this long is a pause (scroll-off, app switch), not a slow frame.
        guard interval > 0, interval < 0.25 else { return quality }
        average += (interval - average) * 0.1
        if average > 1.0 / 48.0 {
            slowFrames += 1
            healthyFrames = 0
            if slowFrames >= 30, let lower = OrganicScoreQuality(rawValue: quality.rawValue - 1) {
                quality = lower
                slowFrames = 0
            }
        } else {
            slowFrames = 0
            healthyFrames += 1
            if healthyFrames >= 600, let higher = OrganicScoreQuality(rawValue: quality.rawValue + 1) {
                quality = higher
                healthyFrames = 0
            }
        }
        return quality
    }

    func pause() { lastTime = nil }
}

/// The single display clock for Liquid Today's three score rings. Keeping the timeline here prevents
/// three independent 60 Hz loops from drifting out of phase or scheduling redundant view updates, and
/// makes this the one owner of the hero's claim on the shared motion sensor.
struct OrganicScoreHeroClock<Content: View>: View {
    let dataReady: Bool
    @ViewBuilder let content: (OrganicScoreFrame) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dashboardIsActive) private var dashboardIsActive
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var motion = NoopMotionState.shared
    @AppStorage(OrganicScoreMotionPrefs.reactsToMovementKey)
    private var reactsToMovement = OrganicScoreMotionPrefs.reactsToMovementDefault
    @State private var isVisible = true
    @State private var holdsSensor = false
    @State private var governor = OrganicScoreFrameGovernor()

    private var gate: OrganicScoreAnimationGate {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let hasSensor = true
        #else
        let hasSensor = false
        #endif
        return OrganicScoreAnimationGate(
            dataReady: dataReady,
            reduceMotion: reduceMotion,
            quietMotion: motion.quietMotion,
            lowPower: motion.isLowPower,
            windowObscured: motion.windowObscured,
            sceneActive: scenePhase == .active,
            tabActive: dashboardIsActive,
            heroVisible: isVisible,
            reactsToDeviceMovement: reactsToMovement,
            platformHasMotionSensor: hasSensor
        )
    }

    var body: some View {
        let gate = gate
        rendered(gate)
            .dashboardAnimationVisibility($isVisible)
            .onAppear { syncSensor(gate.readsMotionSensor) }
            .onDisappear { syncSensor(false) }
            .onChangeCompat(of: gate.readsMotionSensor) { syncSensor($0) }
    }

    @ViewBuilder
    private func rendered(_ gate: OrganicScoreAnimationGate) -> some View {
        if gate.runsFrameClock {
            let readsMotion = gate.readsMotionSensor
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let time = liquidSeconds(timeline.date)
                content(OrganicScoreFrame(
                    time: time,
                    isAnimating: true,
                    motion: readsMotion ? LiquidMotion.shared.organicMotion : .still,
                    quality: governor.record(time)
                ))
            }
            .onDisappear { governor.pause() }
        } else {
            content(.still)
        }
    }

    /// Acquire/release exactly once per transition so the ref count shared with the vessels stays exact.
    private func syncSensor(_ wanted: Bool) {
        guard wanted != holdsSensor else { return }
        holdsSensor = wanted
        if wanted { LiquidMotion.shared.acquire() } else { LiquidMotion.shared.release() }
    }
}

/// One stable-centre organic score ring. Geometry, particles and the value morph come from the pure,
/// deterministic `OrganicScoreVisualModel`; the Canvas only turns that contract into pixels. The
/// number sits above every layer and never moves.
struct OrganicScoreRing: View {
    let model: OrganicScoreVisualModel
    let tint: Color
    let score: Double?
    let decimals: Int
    let frame: OrganicScoreFrame
    var diameter: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0
    @State private var morph: OrganicScoreMorph?
    @State private var previousTint: Color?
    @State private var tintStart: Double = -.infinity
    /// The tint the ring last settled on. `tint` itself already holds the NEW colour by the time a
    /// change is observed, so the old one has to be remembered here to fade out of.
    @State private var settledTint: Color?

    var body: some View {
        ZStack {
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let current = frame.isAnimating
                    ? (morph ?? .settled(model)).model(at: frame.time)
                    : model
                let time = frame.isAnimating ? frame.time : 0
                let fade = frame.isAnimating ? tintProgress(at: frame.time) : 1
                if let previousTint, fade < 1 {
                    var old = context
                    old.opacity = 1 - fade
                    OrganicScoreRingRenderer.draw(context: &old, size: size, model: current, tint: previousTint,
                                                  time: time, motion: frame.motion, quality: frame.quality)
                    context.opacity = fade
                }
                OrganicScoreRingRenderer.draw(context: &context, size: size, model: current, tint: resolvedTint,
                                              time: time, motion: frame.motion, quality: frame.quality)
            }

            Group {
                if score != nil {
                    CountUpNumber(
                        value: shown,
                        font: StrandFont.rounded(diameter * 0.27),
                        decimals: decimals
                    )
                } else {
                    Text(verbatim: "–")
                        .font(StrandFont.rounded(diameter * 0.27))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(StrandPalette.onDarkPrimary)
            .shadow(color: .black.opacity(0.72), radius: 4, y: 1)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .frame(width: diameter * 0.56)
            .allowsHitTesting(false)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .onAppear {
            morph = .settled(model)
            settledTint = resolvedTint
            roll(to: score)
        }
        .onChangeCompat(of: model) { retarget(to: $0) }
        .onChangeCompat(of: score) { roll(to: $0) }
    }

    private var resolvedTint: Color { model.state == .missing ? StrandPalette.organicMissing : tint }

    private var animatesChanges: Bool { frame.isAnimating && !reduceMotion }

    private func retarget(to target: OrganicScoreVisualModel) {
        let now = liquidSeconds(Date())
        let base = morph ?? .settled(target)
        morph = base.retargeted(target, at: now, animated: animatesChanges)
        let newTint = resolvedTint
        let oldTint = settledTint ?? newTint
        settledTint = newTint
        if animatesChanges, oldTint != newTint {
            previousTint = oldTint
            tintStart = now
        } else {
            previousTint = nil
        }
    }

    private func tintProgress(at time: Double) -> Double {
        guard tintStart.isFinite else { return 1 }
        return min(max((time - tintStart) / OrganicScoreMorph.duration, 0), 1)
    }

    private func roll(to value: Double?) {
        guard let value else { shown = 0; return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: OrganicScoreMorph.duration)) {
            shown = value
        }
    }
}

private enum OrganicScoreRingRenderer {
    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        model: OrganicScoreVisualModel,
        tint: Color,
        time: Double,
        motion: OrganicScoreMotionInput,
        quality: OrganicScoreQuality
    ) {
        let side = min(size.width, size.height)
        guard side > 0 else { return }

        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = side * OrganicScoreVisualModel.baseRadiusFraction
        let samples = quality.contourSamples
        let primary = closedPath(centre: centre, radius: radius, samples: samples) { angle in
            model.contourRadius(angle: angle, time: time, motion: motion)
        }
        let isMissing = model.state == .missing

        drawInnerAtmosphere(context: &context, centre: centre, radius: radius, tint: tint,
                            intensity: model.intensity)

        for (index, visibility) in model.echoVisibilities(quality: quality).enumerated() {
            let echo = closedPath(centre: centre, radius: radius, samples: samples) { angle in
                model.echoRadius(index: index, angle: angle, time: time, motion: motion)
            }
            context.stroke(echo, with: .color(tint.opacity((0.18 - Double(index) * 0.035) * visibility)),
                           lineWidth: 1.15)
        }

        if quality.drawsSmoke, model.intensity.smokeStrength > 0 {
            let smoke = model.intensity.smokeStrength
            // Smoke drifts a couple of points downhill; the contour it surrounds does not.
            let drift = CGSize(width: motion.gravity.x * 2.2, height: motion.gravity.y * 2.2)
            context.drawLayer { layer in
                layer.translateBy(x: drift.width, y: drift.height)
                layer.addFilter(.blur(radius: 3.5 + smoke * 3.5))
                layer.stroke(primary, with: .color(tint.opacity(0.10 + smoke * 0.14)),
                             lineWidth: 3 + smoke * 4.5)
            }
        }

        let particleScale = side / 104
        for index in 0..<model.particleCount(quality: quality) {
            guard let particle = model.particle(index: index, time: time, motion: motion) else { continue }
            let size = particle.size * particleScale
            let rect = CGRect(x: centre.x + particle.x * radius - size / 2,
                              y: centre.y + particle.y * radius - size / 2,
                              width: size, height: size)
            context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(particle.alpha)))
        }

        context.drawLayer { layer in
            layer.addFilter(.shadow(color: tint.opacity(0.55 + model.intensity.glowStrength * 0.35),
                                    radius: 3 + model.intensity.glowStrength * 3))
            layer.stroke(primary, with: .color(tint.opacity(isMissing ? 0.52 : 0.96)),
                         lineWidth: isMissing ? 1.15 : 1.7)
        }
        context.stroke(primary, with: .color(.white.opacity(isMissing ? 0.12 : 0.46)), lineWidth: 0.55)
    }

    private static func drawInnerAtmosphere(
        context: inout GraphicsContext,
        centre: CGPoint,
        radius: CGFloat,
        tint: Color,
        intensity: OrganicScoreIntensity
    ) {
        let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        let glow = 0.055 + intensity.glowStrength * 0.14
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [tint.opacity(glow * 0.42), tint.opacity(glow), .clear]),
                center: centre,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    private static func closedPath(
        centre: CGPoint,
        radius: CGFloat,
        samples: Int,
        radiusAt: (Double) -> Double
    ) -> Path {
        var path = Path()
        for index in 0..<samples {
            let angle = Double(index) / Double(samples) * Double.pi * 2
            let r = radius * radiusAt(angle)
            let point = CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
