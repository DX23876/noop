import SwiftUI

// MARK: - The coach's breath

/// A ring of many short spikes — a corona, not a glow.
///
/// The coach entry used to breathe as a 104pt tile, where a 3% swell was plainly visible. It now lives
/// as a 30pt button in the Today header, and 3% of 30pt is 0.9pt: a scale pulse that small reads as
/// nothing at all. A spiked ring swelling behind the avatar carries the same "it is alive" signal at a
/// size where movement cannot.
///
/// Pure geometry with no view state, so the path is unit-testable without a renderer.
public struct SpikedHaloShape: Shape {
    /// How many spikes go round the ring. Enough that they read as a fine corona rather than as a
    /// countable star.
    public var spikes: Int
    /// Where a spike's base sits, as a fraction of the outer radius. Closer to 1 gives shorter, finer
    /// teeth; 1.0 exactly degenerates to a plain circle.
    public var innerRatio: CGFloat

    public init(spikes: Int = 24, innerRatio: CGFloat = 0.82) {
        self.spikes = spikes
        self.innerRatio = innerRatio
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let outer = min(rect.width, rect.height) / 2
        // A zero-sized rect (a view laid out before its frame resolves) must produce an empty path
        // rather than a NaN-ridden one, and fewer than three spikes cannot enclose an area.
        guard outer > 0, spikes >= 3 else { return path }
        let inner = outer * max(0, min(1, innerRatio))
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // Two vertices per spike — tip, then base — walked once around the circle.
        let step = .pi / CGFloat(spikes)
        for index in 0..<(spikes * 2) {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = CGFloat(index) * step - .pi / 2
            let point = CGPoint(x: centre.x + cos(angle) * radius,
                                y: centre.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

public extension View {
    /// Put the breathing corona behind this view — the Coach entry's "I am here" pulse.
    ///
    /// `active` is the caller's own gate (the user's setting AND the motion state); this modifier only
    /// owns the animation, so the two decisions stay where they belong. Drawn BEHIND, hit-testing off
    /// and hidden from VoiceOver: it is decoration, and it must never take a tap meant for the button
    /// it sits under.
    func coachBreathHalo(active: Bool, tint: Color = StrandPalette.accent) -> some View {
        modifier(CoachBreathHaloModifier(active: active, tint: tint))
    }
}

private struct CoachBreathHaloModifier: ViewModifier {
    let active: Bool
    let tint: Color

    /// Flipped once on appear to start the endless breath, exactly as the old tile did.
    @State private var breathing = false

    /// How far past the avatar the corona reaches at rest, and how much further it swells. Kept small:
    /// in the Today header the neighbouring control is only 8pt away, and a corona that laps over it
    /// would read as a rendering fault rather than as a pulse.
    private let restScale: CGFloat = 1.16
    private let breathScale: CGFloat = 1.30

    func body(content: Content) -> some View {
        content
            .background {
                SpikedHaloShape()
                    .fill(tint.opacity(active && breathing ? 0.55 : 0.25))
                    .scaleEffect(active && breathing ? breathScale : restScale)
                    .animation(active ? .easeInOut(duration: 2).repeatForever(autoreverses: true) : nil,
                               value: breathing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onAppear { if active { breathing = true } }
            // Turning the setting off mid-session must settle it immediately, not at the end of an
            // endless animation that never ends. (Carried over from the tile this replaces.)
            .onChangeCompat(of: active) { on in breathing = on }
    }
}
