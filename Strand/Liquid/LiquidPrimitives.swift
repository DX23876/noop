//  LiquidPrimitives.swift
//  NOOP · Liquid design language
//
//  The Canvas renderers + SwiftUI view wrappers for the signature elements:
//  the circular vessel gauge, the horizontal tube, and the live heart-rate thread.
//  Each view owns a LiquidSim, steps it from a TimelineView clock, and reads the
//  one shared tilt source. Colours come from StrandDesign tokens at the call site.

import SwiftUI

// MARK: - Renderers (pure GraphicsContext drawing)

enum LiquidRender {

    /// A circular vessel of liquid filled to `sim.level`, tinted, with parallax
    /// slosh, a light band that follows tilt, surface glints, flake and droplets.
    static func vessel(_ base: GraphicsContext, _ size: CGSize, _ sim: LiquidSim, now: Double, tint: Color) {
        // Floor at 1 so a degenerate sub-3pt Canvas can't drive R negative (negative well rect / chord math).
        let R = max(1, min(size.width, size.height) / 2 - 1.5)
        let ext = R * 1.8
        let cx = size.width / 2, cy = size.height / 2
        let well = CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R)

        var ctx = base
        ctx.translateBy(x: cx, y: cy)
        ctx.fill(Path(ellipseIn: well), with: .color(Color(.sRGB, red: 10/255, green: 11/255, blue: 16/255, opacity: 0.55)))

        var body = ctx
        body.clip(to: Path(ellipseIn: well))

        let lv = sim.level
        if lv > 0.004 {
            let sy = R * (1 - 2 * min(0.985, lv))
            let amp = (0.018 + sim.energy * 0.09) * R

            // helper to build a wave polygon in a given (already-transformed) context
            func wavePolygon(_ w: (Double) -> Double) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: -ext, y: w(-ext)))
                var x = -ext + 4
                while x <= ext { p.addLine(to: CGPoint(x: x, y: w(x))); x += 4 }
                p.addLine(to: CGPoint(x: ext, y: w(ext)))
                p.addLine(to: CGPoint(x: ext, y: R * 2.4))
                p.addLine(to: CGPoint(x: -ext, y: R * 2.4))
                p.closeSubpath()
                return p
            }
            func surfaceLine(_ w: (Double) -> Double) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: -ext, y: w(-ext)))
                var x = -ext + 4
                while x <= ext { p.addLine(to: CGPoint(x: x, y: w(x))); x += 4 }
                p.addLine(to: CGPoint(x: ext, y: w(ext)))
                return p
            }

            // back parallax layer
            let syB = sy - R * 0.04
            let hwB = liquidChordHW(R, syB)
            let wB: (Double) -> Double = {
                liquidWave($0, amp: amp, R: R, hw: hwB, curl: liquidCurl(sim.abv),
                           ph1: sim.p1 * 0.92 + 2.1, ph2: sim.p2 * 0.9 + 1.3, ampMul: 1.35)
            }
            var backCtx = body
            backCtx.translateBy(x: 0, y: syB)
            backCtx.rotate(by: .radians(sim.ab))
            backCtx.fill(wavePolygon(wB), with: .color(tint.opacity(0.28)))

            // main body
            let hw = liquidChordHW(R, sy)
            let w: (Double) -> Double = {
                liquidWave($0, amp: amp, R: R, hw: hw, curl: liquidCurl(sim.av),
                           ph1: sim.p1, ph2: sim.p2, ampMul: 1)
            }
            var mainCtx = body
            mainCtx.translateBy(x: 0, y: sy)
            mainCtx.rotate(by: .radians(sim.a))
            mainCtx.fill(wavePolygon(w),
                         with: .linearGradient(Gradient(colors: [tint.opacity(0.74),
                                                                  tint.liquidDarker(0.28).opacity(0.80)]),
                                               startPoint: CGPoint(x: 0, y: -amp),
                                               endPoint: CGPoint(x: 0, y: R * 1.7)))

            // a sheet of light gliding across as you tilt
            var bandCtx = mainCtx
            bandCtx.clip(to: wavePolygon(w))
            let bandX = -sim.a * R * 2.2 + sin(now * 0.3) * R * 0.15
            bandCtx.fill(Path(CGRect(x: -R * 2.4, y: -R * 2.4, width: R * 4.8, height: R * 4.8)),
                         with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.06), .white.opacity(0)]),
                                               startPoint: CGPoint(x: bandX - R * 1.2, y: 0),
                                               endPoint: CGPoint(x: bandX + R * 1.2, y: 0)))

            // surface sheen + glints + line
            mainCtx.fill(Path(CGRect(x: -ext, y: 0, width: ext * 2, height: R * 0.15)),
                         with: .linearGradient(Gradient(colors: [.white.opacity(0.09), .white.opacity(0)]),
                                               startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: R * 0.15)))
            var gx = -hw
            while gx <= hw {
                let slope = (w(gx + 3) - w(gx - 3)) / 6
                if abs(slope) < 0.05 {
                    let o = 0.22 * (1 - abs(slope) / 0.05)
                    mainCtx.fill(Path(CGRect(x: gx - 2, y: w(gx) - 0.8, width: 4, height: 1.4)), with: .color(.white.opacity(o)))
                }
                gx += 6
            }
            mainCtx.stroke(surfaceLine(w), with: .color(.white.opacity(0.45)), lineWidth: 1.3)

            // droplets
            for b in sim.drops {
                let rr = max(0.7, b.r * R)
                mainCtx.fill(Path(ellipseIn: CGRect(x: b.x * R - rr, y: b.y * R - rr, width: 2 * rr, height: 2 * rr)),
                             with: .color(.white.opacity(min(0.55, b.life * 0.5) * 0.5)))
            }

            // suspended flake (circle frame, only inside the liquid)
            let sa = sin(sim.a), ca = cos(sim.a)
            for f in sim.flecks {
                let fx = f.x * R, fy = f.y * R
                if fx * fx + fy * fy > R * R * 0.9 { continue }
                if -fx * sa + (fy - sy) * ca < R * 0.02 { continue }
                let sVal = sin(f.ph + fx * 0.12 + sim.a * 5 + now * f.sp)
                let spark = pow(max(0, sVal), 10)
                let sz = 0.7 + f.z * 1.0 + spark * 1.4
                let shade: Color
                switch f.kind {
                case 2: shade = Color(.sRGB, red: 8/255, green: 10/255, blue: 13/255, opacity: 0.12 + spark * 0.22)
                case 1: shade = tint.liquidMix(.white, 0.55).opacity(0.10 + spark * 0.8)
                default: shade = .white.opacity(0.08 * f.z + spark * 0.85)
                }
                body.fill(Path(CGRect(x: fx - sz / 2, y: fy - sz / 2, width: sz, height: sz)), with: .color(shade))
            }
        }

        // inner top shadow
        body.fill(Path(CGRect(x: -R, y: -R, width: 2 * R, height: R * 0.75)),
                  with: .linearGradient(Gradient(colors: [.black.opacity(0.30), .black.opacity(0)]),
                                        startPoint: CGPoint(x: 0, y: -R), endPoint: CGPoint(x: 0, y: -R * 0.30)))
        // soft top-left highlight
        body.fill(Path(ellipseIn: CGRect(x: -R * 0.72, y: -R * 0.78, width: R * 0.9, height: R * 0.5)),
                  with: .radialGradient(Gradient(colors: [.white.opacity(0.09), .white.opacity(0)]),
                                        center: CGPoint(x: -R * 0.27, y: -R * 0.5), startRadius: 0, endRadius: R * 0.55))
        // rim
        ctx.stroke(Path(ellipseIn: well), with: .color(tint.opacity(0.22)), lineWidth: 1.25)
    }

    /// A horizontal capsule tube filled to `frac`; tilt pushes the liquid along it.
    static func tube(_ base: GraphicsContext, _ size: CGSize, _ sim: LiquidSim, now: Double, frac: Double, tint: Color) {
        let w = size.width, h = size.height, r = h / 2
        let outline = Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1), cornerRadius: r)
        var ctx = base
        ctx.fill(outline, with: .color(Color(.sRGB, red: 14/255, green: 14/255, blue: 18/255, opacity: 1)))
        ctx.stroke(outline, with: .color(.white.opacity(0.07)), lineWidth: 1)

        var clip = ctx
        clip.clip(to: outline)
        let shift = -sim.a * h * 1.3
        let edge = max(r * 0.8, min(w - 2, frac * (w - 4) + shift))
        let bulge = r * 0.6 + sin(sim.p1 * 2) * sim.energy * h * 0.3 - 0.01 * h * 6
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: edge - r * 0.3, y: 0))
        p.addQuadCurve(to: CGPoint(x: edge - r * 0.3, y: h), control: CGPoint(x: edge + bulge, y: h / 2))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        clip.fill(p, with: .linearGradient(Gradient(colors: [tint.opacity(0.84), tint.liquidDarker(0.28).opacity(0.86)]),
                                           startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
        clip.fill(Path(CGRect(x: 2, y: 1.2, width: max(0, edge - r * 0.6), height: 1)), with: .color(.white.opacity(0.12)))
        for i in 0..<min(8, sim.flecks.count) {
            let f = sim.flecks[i]
            let spark = pow(max(0, sin(f.ph + sim.a * 5 + now * f.sp)), 10)
            if spark < 0.08 { continue }
            let fx = 3 + (f.x + 1.05) / 2.1 * max(1, edge - 8)
            clip.fill(Path(CGRect(x: fx, y: h * 0.15 + f.z * h * 0.7, width: 1 + spark, height: 1 + spark)), with: .color(.white.opacity(spark * 0.6)))
        }
    }

    /// The live heart-rate curve as a glowing liquid thread with a travelling glint.
    ///
    /// `scrubIndex` (nil = not scrubbing) pins a crosshair + dot on that sample, so a finger dragged
    /// across the thread has something to point at while the caller's readout follows it.
    static func thread(_ base: GraphicsContext, _ size: CGSize, values: [Double], now: Double,
                       tint: Color, scrubIndex: Int? = nil) {
        guard values.count >= 2 else { return }
        let w = size.width, h = size.height, pad = LiquidThreadGeometry.pad
        // Plot geometry lives in ONE place (LiquidThreadGeometry) so the drawn curve and a scrub
        // readout mapped back from a touch x can't drift apart. Bounds are resolved once per frame:
        // re-deriving min/max per point would be O(n²) at 60fps over a ~288-bucket day.
        let bounds = LiquidThreadGeometry.bounds(values)
        let n = values.count
        func px(_ i: Int) -> Double { LiquidThreadGeometry.x(index: i, count: n, width: w) }
        func py(_ v: Double) -> Double { LiquidThreadGeometry.y(value: v, bounds: bounds, height: h) }
        func curve() -> Path {
            var p = Path()
            p.move(to: CGPoint(x: px(0), y: py(values[0])))
            for i in 1..<(n - 1) {
                let xc = (px(i) + px(i + 1)) / 2, yc = (py(values[i]) + py(values[i + 1])) / 2
                p.addQuadCurve(to: CGPoint(x: xc, y: yc), control: CGPoint(x: px(i), y: py(values[i])))
            }
            p.addLine(to: CGPoint(x: px(n - 1), y: py(values[n - 1])))
            return p
        }
        var ctx = base
        ctx.stroke(curve(), with: .color(tint.opacity(0.9)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        // travelling glint
        let phase = -(now * 55).truncatingRemainder(dividingBy: 414)
        ctx.stroke(curve(), with: .color(.white.opacity(0.55)),
                   style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [14, 400], dashPhase: phase))
        // endpoint pulse
        let ex = px(n - 1), ey = py(values[n - 1])
        let pr = 3 + sin(now * 6) * 1.1
        ctx.fill(Path(ellipseIn: CGRect(x: ex - pr - 4, y: ey - pr - 4, width: (pr + 4) * 2, height: (pr + 4) * 2)), with: .color(tint.opacity(0.15)))
        ctx.fill(Path(ellipseIn: CGRect(x: ex - pr, y: ey - pr, width: pr * 2, height: pr * 2)), with: .color(tint))

        // scrub crosshair: a hairline down the plot plus a ringed dot on the sample under the finger.
        if let si = scrubIndex, si >= 0, si < n {
            let sx = px(si), sy = py(values[si])
            var hair = Path()
            hair.move(to: CGPoint(x: sx, y: pad * 0.2))
            hair.addLine(to: CGPoint(x: sx, y: h - pad * 0.2))
            ctx.stroke(hair, with: .color(.white.opacity(0.28)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.fill(Path(ellipseIn: CGRect(x: sx - 9, y: sy - 9, width: 18, height: 18)), with: .color(tint.opacity(0.18)))
            ctx.fill(Path(ellipseIn: CGRect(x: sx - 4, y: sy - 4, width: 8, height: 8)), with: .color(.white))
            ctx.stroke(Path(ellipseIn: CGRect(x: sx - 4.5, y: sy - 4.5, width: 9, height: 9)), with: .color(tint), lineWidth: 2)
        }
    }
}

/// The heart-rate thread's plot geometry, stated ONCE: the renderer draws through it and a scrub
/// gesture maps a touch position back through it, so the dot under the finger is always the value the
/// readout shows. Pure math — no SwiftUI state, testable, and shared by every `LiquidThread`.
enum LiquidThreadGeometry {
    /// The inset the curve is drawn with, on all four sides.
    static let pad: Double = 10

    /// Value range for the vertical scale: the series' own min, with a 10 bpm floor on the span so a
    /// flat resting trace doesn't get amplified into noise.
    static func bounds(_ values: [Double]) -> (min: Double, span: Double) {
        guard !values.isEmpty else { return (0, 10) }
        var mn = Double.greatestFiniteMagnitude, mx = -Double.greatestFiniteMagnitude
        for v in values { mn = min(mn, v); mx = max(mx, v) }
        return (mn, max(10, mx - mn))
    }

    static func x(index: Int, count: Int, width: Double) -> Double {
        guard count > 1 else { return width / 2 }
        return pad + Double(index) * (width - 2 * pad) / Double(count - 1)
    }

    static func y(value: Double, bounds: (min: Double, span: Double), height: Double) -> Double {
        height - pad - (value - bounds.min) / bounds.span * (height - 2 * pad)
    }

    /// The sample nearest a horizontal position, clamped to the series — so dragging past either end
    /// of the plot rests on the first/last value instead of dropping the readout.
    static func index(atX x: Double, count: Int, width: Double) -> Int {
        guard count > 1 else { return 0 }
        let usable = max(1, width - 2 * pad)
        let t = min(1, max(0, (x - pad) / usable))
        return min(count - 1, max(0, Int((t * Double(count - 1)).rounded())))
    }
}

// MARK: - Views

/// A circular liquid gauge. `value` is 0...1 (nil = empty/no-data). Tap → splash.
///
/// `animated: false` renders a single static frame (no TimelineView, no CoreMotion) — the small
/// gauges in card rows / vitals slosh imperceptibly at 26–30pt but each cost a live 30fps Canvas,
/// so they pose still and CoreAnimation caches them. The big hero gauges stay animated.
struct LiquidVessel: View {
    let value: Double?
    let tint: Color
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var power = LiquidPowerMonitor.shared
    @State private var sim: LiquidSim
    @State private var splashes = 0

    init(value: Double?, tint: Color, animated: Bool = true) {
        self.value = value
        self.tint = tint
        self.animated = animated
        _sim = State(initialValue: LiquidSim(target: value ?? 0))
    }

    var body: some View {
        if animated && !reduceMotion && !power.isLowPower { gauge } else { staticGauge }
    }

    private var gauge: some View {
        // 60fps: on the 120Hz ProMotion panel a 30fps cap updated the fluid only every 4th refresh,
        // which read as juddery slosh. Only the 3 hero gauges + HR thread run live now (the small ones
        // are static), so the higher rate is affordable and the liquid actually flows.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
            let now = liquidSeconds(tl.date)
            Canvas { context, size in
                sim.step(now: now, tilt: LiquidMotion.shared.tilt, target: value ?? 0)
                LiquidRender.vessel(context, size, sim, now: now, tint: tint)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Circle())
        .onTapGesture { sim.splash(12); splashes &+= 1 }
        .liquidTapHaptic(trigger: splashes)   // light tap feedback (guarded so the primitives compile on macOS 13)
        .onAppear { LiquidMotion.shared.acquire() }
        .onDisappear { LiquidMotion.shared.release() }
    }

    /// One-shot, cached render — posed at the fill line, no clock, no motion acquire.
    private var staticGauge: some View {
        Canvas { context, size in
            LiquidRender.vessel(context, size, LiquidSim.posed(value ?? 0), now: 0, tint: tint)
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Circle())
    }
}

/// A horizontal liquid tube filled to `frac` (0...1).
///
/// `animated: false` poses it still and lets CoreAnimation cache the layer — the 8pt grid tubes
/// and 12pt workout bar don't need a live 30fps Canvas each. Hero-adjacent tubes can stay live.
struct LiquidTube: View {
    let frac: Double
    let tint: Color
    var height: CGFloat = 14
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var power = LiquidPowerMonitor.shared
    @State private var sim = LiquidSim(target: 0)

    var body: some View {
        if animated && !reduceMotion && !power.isLowPower { liveTube } else { staticTube }
    }

    private var liveTube: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let now = liquidSeconds(tl.date)
            Canvas { context, size in
                sim.step(now: now, tilt: LiquidMotion.shared.tilt, target: frac)
                LiquidRender.tube(context, size, sim, now: now, frac: max(0, min(1, frac)), tint: tint)
            }
        }
        .frame(height: height)
        .onAppear { LiquidMotion.shared.acquire() }
        .onDisappear { LiquidMotion.shared.release() }
    }

    private var staticTube: some View {
        Canvas { context, size in
            LiquidRender.tube(context, size, LiquidSim.posed(frac), now: 0,
                              frac: max(0, min(1, frac)), tint: tint)
        }
        .frame(height: height)
    }
}

/// The live heart-rate thread. `bpm` is the recent series (any length ≥ 2).
///
/// `scrubIndex` is purely presentational: the OWNER runs the gesture (it knows what the series means
/// and what to put in the readout) and hands the resolved sample index down. Defaults to nil, so the
/// call sites that don't scrub are unchanged.
struct LiquidThread: View {
    let bpm: [Double]
    var tint: Color = Color(.sRGB, red: 1, green: 107/255, blue: 129/255, opacity: 1)
    var height: CGFloat = 96
    var animated: Bool = true
    var scrubIndex: Int? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var power = LiquidPowerMonitor.shared

    var body: some View {
        if animated && !reduceMotion && !power.isLowPower { liveThread } else { staticThread }
    }

    private var liveThread: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in   // 60fps to flow smoothly on ProMotion
            let now = liquidSeconds(tl.date)
            Canvas { context, size in
                LiquidRender.thread(context, size, values: bpm, now: now, tint: tint, scrubIndex: scrubIndex)
            }
        }
        .frame(height: height)
    }

    /// One-shot render (no travelling glint / pulse) — used until first data load settles.
    private var staticThread: some View {
        Canvas { context, size in
            LiquidRender.thread(context, size, values: bpm, now: 0, tint: tint, scrubIndex: scrubIndex)
        }
        .frame(height: height)
    }
}

// MARK: - Shared liquid components (cross-platform: used by Today AND the other liquid screens on iOS + mac)

extension View {
    /// A light selection/impact haptic, available only where `sensoryFeedback` is (iOS 17 / macOS 14);
    /// a no-op below that so the liquid primitives still compile on the macOS 13 deployment target.
    @ViewBuilder func liquidTapHaptic(trigger: some Equatable) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.sensoryFeedback(.impact(weight: .light), trigger: trigger)
        } else {
            self
        }
    }

    /// A selection tick (e.g. the WHOOP-style day change), guarded so it compiles on macOS 13.
    @ViewBuilder func liquidSelectionHaptic(trigger: some Equatable) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }

    /// A firmer medium impact (e.g. the pull-to-refresh release), guarded for the macOS 13 target.
    @ViewBuilder func liquidMediumHaptic(trigger: some Equatable) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.sensoryFeedback(.impact(weight: .medium), trigger: trigger)
        } else {
            self
        }
    }
}

/// The "this card was pressed" response for any tappable liquid card — a small settle inward plus a
/// touch of dimming. Cheap (a transform), so it's free on static cards and makes every tap feel physical.
struct LiquidPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// A number that animates to its value: SwiftUI interpolates `animatableData`, so the shown integer rolls
/// smoothly frame-by-frame whenever `value` changes inside a `withAnimation` block.
struct CountUpNumber: View, Animatable {
    var value: Double
    var font: Font
    /// Decimal places to render. 0 (default) keeps the whole-number scores (Charge/Rest/100-scale Effort)
    /// byte-identical; the WHOOP 0–21 Effort scale passes 1 so the hero matches the app-wide one-decimal
    /// `effortDisplay` convention instead of rounding 12.6 → "13" (#45).
    var decimals: Int = 0
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(decimals > 0 ? String(format: "%.\(decimals)f", value) : "\(Int(value.rounded()))")
            .font(font).monospacedDigit()
    }
}

// MARK: - Liquid Glass (iOS 26) with a Material fallback

extension View {
    /// Real iOS 26 Liquid Glass where available; `.ultraThinMaterial` on iOS 17–25 (and on macOS, which has
    /// no `glassEffect`) — a clean blended degrade so a surface stays modern on new OSes without breaking
    /// older ones. Deliberately used SPARINGLY: each glass surface is its own blur pass, and Today draws a
    /// live animated sky underneath, so this belongs on the floating chrome and the one hero surface, not on
    /// every card and tile (those take a lighter fill instead).
    @ViewBuilder func liquidGlass(in shape: some Shape) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}

// MARK: - Availability shims for the expressive SwiftUI effects
//
// The app ships iOS 17.0 / macOS 13.0, so every "modern" effect below needs a gate — and on macOS the
// bar is one release HIGHER than the iOS equivalent (scrollTransition et al are iOS 17 / macOS 14).
// Wrapping each one here keeps the call sites (the coach chat, mainly) readable instead of drowning them
// in `if #available` ladders, and puts the fallback decision in ONE place per effect.
//
// Every one of these is a no-op when the effect isn't available: the view renders, it just doesn't move.

extension View {
    /// Keep a scroll view pinned to its bottom edge — the natural resting place for a transcript.
    @ViewBuilder func liquidBottomAnchored() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.defaultScrollAnchor(.bottom)
        } else {
            self
        }
    }

    /// Let a downward drag dismiss the keyboard, the way every messenger does. iOS-only: macOS has no
    /// software keyboard to dismiss.
    @ViewBuilder func liquidInteractiveKeyboardDismiss() -> some View {
        #if os(iOS)
        self.scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }

    /// Apple Intelligence Writing Tools in a text field (iOS 18+). Free capability once declared; a no-op
    /// everywhere else.
    @ViewBuilder func liquidWritingTools() -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            self.writingToolsBehavior(.complete)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Crisp (non-fading) top AND bottom scroll edges (iOS 26) for the chat transcript. Used to be a
    /// `.soft` fade at the top only, matching a floating glass bar's "content dissolves beneath it"
    /// look — but a message long enough to span most/all of the screen spends a large fraction of its
    /// text under that fade (top, under the header; bottom, under the docked composer's automatic
    /// system fade) at any given scroll position, which reads as lost legibility rather than polish.
    /// `.hard` keeps the glass bars but cuts content cleanly at their edge instead of dimming it. Below
    /// iOS 26 or on macOS this stays a no-op, same as before.
    @ViewBuilder func liquidCrispChatEdges() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
                .scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Zoom transitions (iOS 18+)

extension View {
    /// Mark this view as the visual SOURCE of a zoom presentation — the presented sheet/detail appears to
    /// grow out of it rather than sliding up from nowhere. Paired with `zoomDestination`. A no-op below
    /// iOS 18 and on macOS, where the standard presentation is already the platform-correct one. Generic —
    /// used by the coach avatar/chart zoom and by tile→detail pushes (metric tiles, Trends/Sleep heroes).
    @ViewBuilder func zoomSource(id: String, namespace: Namespace.ID) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Present this destination (sheet or pushed detail) as a zoom out of the matching source.
    @ViewBuilder func zoomDestination(id: String, namespace: Namespace.ID) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Flow layout

/// Lays subviews out in rows, wrapping to the next line when the current one runs out of width — the
/// "chip cloud" a horizontal `ScrollView` can only fake by hiding half its contents off-screen. Plain
/// `Layout` (iOS 16 / macOS 13), so it needs no availability gate and sizes correctly under Dynamic Type,
/// which is exactly where a fixed-column grid of variable-length chips falls apart.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var total = CGSize(width: 0, height: 0)
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                total.width = max(total.width, rowWidth)
                total.height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        total.width = max(total.width, rowWidth)
        total.height += rowHeight
        return total
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
