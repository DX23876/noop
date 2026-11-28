import SwiftUI

// MARK: - Strand Motion (§9.6)
//
// Physiological motion — breathe / pulse / flow, no cartoon bounce.
// Ring draw-in, per-beat ripple, hover lift, sliding sidebar indicator.

public enum StrandMotion {

    // MARK: Spring presets

    /// Interactive spring — snappy, for direct manipulation (hover, press, sidebar slide).
    public static let interactive = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.1)

    /// Gentle spring — the house style for value changes (ring draw-in, gauges).
    /// spring(response: 0.5, damping: 0.8) per the brief.
    public static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.8)

    /// A slower, more deliberate spring for hero transitions (e.g. first ring materialize).
    public static let hero = Animation.spring(response: 0.85, dampingFraction: 0.85)

    // MARK: Durations

    /// Fast UI feedback (hover lift, chip state).
    public static let durationFast: Double = 0.18

    /// Standard transition (card appear, fades).
    public static let durationStandard: Double = 0.30

    /// Slow / draw-in (ring arc, waveform ignite).
    public static let durationSlow: Double = 0.9

    /// One breath cycle for ambient pulsing (bloom, listening flatline).
    public static let breathPeriod: Double = 3.2

    // MARK: Curves

    /// Ease for the ring/gauge draw-in when a value changes.
    public static let drawIn = Animation.easeOut(duration: durationSlow)

    /// The ring/gauge draw-in, suppressed when Reduce Motion is on. Returns `nil`
    /// (no animation) when reduced so `withAnimation` sets the fraction instantly and
    /// the arc/bead snaps to its final frame instead of sweeping. Mirrors
    /// `breathe(reduced:)` and honours Apple's Reduce Motion HIG.
    public static func drawIn(reduced: Bool) -> Animation? {
        reduced ? nil : drawIn
    }

    /// Looping breathe animation for ambient glow/pulse.
    public static var breathe: Animation {
        .easeInOut(duration: breathPeriod).repeatForever(autoreverses: true)
    }

    /// The breath's position at a wall-clock instant: 0 at rest, 1 at full swell, and back, over two
    /// `breathPeriod`s, eased like `breathe`'s own curve.
    ///
    /// It exists because `breathe` is a `repeatForever` animation, which has to be STARTED by a state
    /// change and is lost when the view leaves the render tree. A pulse that reports live work — a strap
    /// backfilling — then stops reporting it: switch to another tab and back and the dot sits still while
    /// the sync runs on, which is what a wearer saw as "the bar is grey now" (fork issue #48). A function
    /// of the clock cannot be in the wrong state: whatever is on screen draws the phase that the moment
    /// has, started or not.
    ///
    /// The fork already learned this once, for the vitals-grid wiggle (decisions, 2026-07-24).
    public static func breathPhase(at date: Date, period: Double = breathPeriod) -> Double {
        guard period > 0 else { return 0 }
        // Mapped into [0, 2) FIRST: a negative remainder mirrored without mapping sticks at full swell
        // for half of every cycle before the reference instant, which a reader of a "function of the
        // clock" would not expect of it.
        var t = (date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 2)
        if t < 0 { t += 2 }
        let clamped = max(0, min(1, t <= 1 ? t : 2 - t))
        // Smoothstep: the same slow-in/slow-out shape `easeInOut` draws, as a plain function.
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// A sweep's position at a wall-clock instant: 0 to 1 over `period` and straight back to 0, the
    /// shape of a `repeatForever(autoreverses: false)` ring, eased out like its curve.
    ///
    /// Same reason as `breathPhase`: a started animation can be lost, a function of the clock cannot.
    /// The Today header's sync ring is drawn from this, so it keeps reporting an offload that is still
    /// running after the wearer has been to another tab and back (fork issue #48).
    public static func sweepPhase(at date: Date, period: Double) -> Double {
        guard period > 0 else { return 0 }
        let raw = (date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1)
        let t = max(0, min(1, raw < 0 ? raw + 1 : raw))
        // Ease out: quick at the start, settling at the end, as `.easeOut` draws it.
        return 1 - (1 - t) * (1 - t) * (1 - t)
    }

    /// The shortest step between two frames of a pulse drawn from the clock (`breathPhase`, `sweepPhase`).
    ///
    /// A `TimelineView(.animation)` re-evaluates its view on the main thread at the display's own rate, 60 to
    /// 120 times a second, for as long as it is on screen, and these pulses sit there through whole offloads.
    /// The motion they draw is slow (a 3.2-second breath, a 1.1-second sweep), so thirty steps a second reads
    /// the same and halves to quarters that work. The started animation they replace ran on the render
    /// server; this keeps the clock's correctness without paying full frame rate for it.
    public static let clockFrameInterval: Double = 1.0 / 30.0

    /// Looping breathe animation, suppressed when Reduce Motion is on. Returns
    /// `nil` (no animation) when reduced so call sites collapse to the resting
    /// frame instead of an indefinite loop. Honours Apple's Reduce Motion HIG.
    public static func breathe(reduced: Bool) -> Animation? {
        reduced ? nil : breathe
    }

    /// A single heartbeat ripple pulse.
    public static let pulse = Animation.easeOut(duration: 0.6)

    /// Standard fade.
    public static let fade = Animation.easeInOut(duration: durationStandard)

    // MARK: Sync signal

    /// Grace period the SCREEN applies to the falling edge of the sync signal before its sync indicator
    /// stops. Public because the raw signal is the screen's to own: `backfilling` drops between history
    /// chunks, and without this the indicator would flicker off in the middle of one logical sync.
    public static let syncIndicatorSignalDebounceNanoseconds: UInt64 = 3_000_000_000
}

#if DEBUG
private struct MotionDemo: View {
    @State private var on = false
    @State private var breathing = false
    var body: some View {
        VStack(spacing: 32) {
            Circle()
                .fill(StrandPalette.accent)
                .frame(width: 60, height: 60)
                .offset(y: on ? -24 : 24)
                .animation(StrandMotion.gentle, value: on)
            Circle()
                .fill(StrandPalette.recovery100)
                .frame(width: 60, height: 60)
                .scaleEffect(breathing ? 1.12 : 0.9)
                .opacity(breathing ? 0.9 : 0.5)
                .onAppear { breathing = true }
                .animation(StrandMotion.breathe, value: breathing)
            Button("Toggle gentle spring") { on.toggle() }
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(width: 360, height: 320)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
    }
}

#Preview("Motion") { MotionDemo() }
#endif
