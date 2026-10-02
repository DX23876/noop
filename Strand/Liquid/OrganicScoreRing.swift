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
    @Environment(\.colorScheme) private var colorScheme
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
                let onLight = colorScheme == .light
                if let previousTint, fade < 1 {
                    var old = context
                    old.opacity = 1 - fade
                    OrganicScoreRingRenderer.draw(context: &old, size: size, model: current, tint: previousTint,
                                                  time: time, motion: frame.motion, quality: frame.quality, onLight: onLight,
                                                  live: frame.isAnimating)
                    context.opacity = fade
                }
                OrganicScoreRingRenderer.draw(context: &context, size: size, model: current, tint: resolvedTint,
                                              time: time, motion: frame.motion, quality: frame.quality,
                                              onLight: onLight, live: frame.isAnimating)
            }
            // Echoes and smoke reach past the ring's own square; the canvas overscans so they fade out
            // instead of being cut at its edge. Layout and the hit target stay at `diameter`.
            .frame(width: diameter * OrganicScoreRingRenderer.overscan,
                   height: diameter * OrganicScoreRingRenderer.overscan)
            .allowsHitTesting(false)

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
            // Light hero card: page ink with a faint paper halo; dark chamber: on-dark ink with a shadow.
            .foregroundStyle(colorScheme == .light ? StrandPalette.textPrimary : StrandPalette.onDarkPrimary)
            .shadow(color: colorScheme == .light ? .white.opacity(0.85) : .black.opacity(0.72),
                    radius: colorScheme == .light ? 3 : 4, y: colorScheme == .light ? 0 : 1)
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
    /// Canvas size relative to the ring's layout square.
    static let overscan: CGFloat = 1.3

    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        model: OrganicScoreVisualModel,
        tint: Color,
        time: Double,
        motion: OrganicScoreMotionInput,
        quality: OrganicScoreQuality,
        onLight: Bool,
        live: Bool
    ) {
        let side = min(size.width, size.height) / overscan
        guard side > 0 else { return }

        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = side * OrganicScoreVisualModel.baseRadiusFraction
        let samples = quality.contourSamples
        let primary = closedPath(centre: centre, radius: radius, samples: samples) { angle in
            model.contourRadius(angle: angle, time: time, motion: motion)
        }
        let isMissing = model.state == .missing
        let glow = model.intensity.glowStrength
        // The static path (Reduce Motion, quiet motion, off screen) sits at a neutral breath.
        let breathe = live ? model.breathBrightness(time: time) : 1
        let band = CGFloat(model.bandHalfWidth) * radius
        // Light on dark adds up (the reference's luminous look); on the light card that would wash out
        // to white, so it blends normally there.
        let blend: GraphicsContext.BlendMode = onLight ? .normal : .plusLighter

        drawInnerAtmosphere(context: &context, centre: centre, radius: radius, tint: tint,
                            intensity: model.intensity)

        // Bloom: the whole band, thick and blurred, behind everything else.
        if !isMissing {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 5 + glow * 9))
                layer.stroke(primary,
                             with: .color(tint.opacity(min(1, ((onLight ? 0.22 : 0.35) + glow * 0.4) * breathe))),
                             lineWidth: (band * 2.6 + 4) * (0.9 + 0.1 * breathe))
            }
        }

        for (index, visibility) in model.echoVisibilities(quality: quality).enumerated() {
            let echo = closedPath(centre: centre, radius: radius, samples: samples) { angle in
                model.echoRadius(index: index, angle: angle, time: time, motion: motion)
            }
            context.stroke(echo, with: .color(tint.opacity((0.16 - Double(index) * 0.03) * visibility)),
                           lineWidth: 0.9)
        }

        if quality.drawsSmoke, model.intensity.smokeStrength > 0 {
            let smoke = model.intensity.smokeStrength
            // Smoke drifts a couple of points downhill; the contour it surrounds does not.
            let drift = CGSize(width: motion.gravity.x * 2.2, height: motion.gravity.y * 2.2)
            context.drawLayer { layer in
                layer.translateBy(x: drift.width, y: drift.height)
                layer.addFilter(.blur(radius: 3 + smoke * 4))
                layer.stroke(primary, with: .color(tint.opacity((onLight ? 0.10 : 0.16) + smoke * 0.2)),
                             lineWidth: band * 1.6 + 3)
            }
        }

        // Haze filling the band, so the strands sit in luminous volume rather than reading as wires.
        if !isMissing {
            context.drawLayer { layer in
                layer.blendMode = blend
                layer.addFilter(.blur(radius: 1.5 + glow * 2.5))
                layer.stroke(primary,
                             with: .color(tint.opacity(min(1, ((onLight ? 0.18 : 0.22) + glow * 0.3) * breathe))),
                             lineWidth: band * 2)
            }
        }

        // The band itself: fine strands weaving across its width, brightest in the middle.
        let strands = model.filamentCount(quality: quality)
        context.drawLayer { layer in
            layer.blendMode = blend
            for index in 0..<strands {
                let strand = strands == 1 ? primary
                    : closedPath(centre: centre, radius: radius, samples: samples) { angle in
                        model.filamentRadius(index: index, count: strands, angle: angle, time: time, motion: motion)
                    }
                let middle = strands == 1 ? 1 : 1 - abs(Double(index) / Double(strands - 1) * 2 - 1)
                let alpha = isMissing ? 0.5 : (0.28 + 0.5 * middle) * (0.55 + glow * 0.45)
                layer.stroke(strand, with: .color(tint.opacity(alpha)),
                             lineWidth: isMissing ? 1.15 : 0.7 + middle * 0.8)
            }
        }

        let particleScale = side / 104
        let core = onLight ? tint : tint.liquidLighter(0.55)   // resolved once, not per particle
        context.drawLayer { layer in
            layer.blendMode = blend
            for index in 0..<model.particleCount(quality: quality) {
                guard let particle = model.particle(index: index, time: time, motion: motion) else { continue }
                let size = particle.size * particleScale
                let point = CGPoint(x: centre.x + particle.x * radius, y: centre.y + particle.y * radius)
                if size > 1.7 {
                    // A sparkle carries a soft halo.
                    let halo = size * 2.6
                    layer.fill(Path(ellipseIn: CGRect(x: point.x - halo / 2, y: point.y - halo / 2,
                                                      width: halo, height: halo)),
                               with: .color(tint.opacity(particle.alpha * 0.25)))
                }
                layer.fill(Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2,
                                                  width: size, height: size)),
                           with: .color(core.opacity(min(1, particle.alpha * (onLight ? 1 : 1.25)))))
            }
        }

        // A bright filament core on the principal contour, so the shape stays crisp inside the haze.
        if !isMissing && !onLight {
            context.stroke(primary, with: .color(.white.opacity(0.18 + glow * 0.35)), lineWidth: 0.6)
        }
    }

    private static func drawInnerAtmosphere(
        context: inout GraphicsContext,
        centre: CGPoint,
        radius: CGFloat,
        tint: Color,
        intensity: OrganicScoreIntensity
    ) {
        let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        let glow = 0.05 + intensity.glowStrength * 0.16
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: tint.opacity(glow * 0.25), location: 0.55),
                    .init(color: tint.opacity(glow), location: 0.92),
                    .init(color: .clear, location: 1),
                ]),
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
