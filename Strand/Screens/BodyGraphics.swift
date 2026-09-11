import SwiftUI
import StrandDesign

// MARK: - Small drawings for the body and energy screens
//
// Each of these exists because a number alone was under-selling what it says.
//
// The corridor is the clearest case. "2 496, 2 141, and they disagree by 355" is three figures the
// reader has to hold in their head and subtract. Drawn on one axis it is a single glance: how far
// apart, in which direction, and which route sits where. The spread was always the point of that card
// — this is the form in which it actually reads as one.

/// Three daily-energy estimates on one axis, with the spread between the extremes drawn as a band.
///
/// Deliberately unlabelled by "good" or "bad": a corridor is a statement about uncertainty, not about
/// whether the wearer is doing well. Colour distinguishes the ROUTES, nothing else.
struct CorridorBar: View {
    struct Entry: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let entries: [Entry]

    private var values: [Double] { entries.map(\.value) }

    /// A little air either side, so a marker at an extreme is not clipped to the edge.
    private var domain: ClosedRange<Double>? {
        guard let low = values.min(), let high = values.max(), high > low else { return nil }
        let pad = max((high - low) * 0.25, 40)
        return (low - pad)...(high + pad)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            if let domain, let low = values.min(), let high = values.max() {
                let span = domain.upperBound - domain.lowerBound
                let x = { (value: Double) in (value - domain.lowerBound) / span * width }
                ZStack(alignment: .topLeading) {
                    // The axis.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(StrandPalette.hairline)
                        .frame(height: 3)
                        .offset(y: 16)
                    // The spread itself — the thing the card is about.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(StrandPalette.textTertiary.opacity(0.45))
                        .frame(width: max(2, x(high) - x(low)), height: 3)
                        .offset(x: x(low), y: 16)
                    ForEach(entries) { entry in
                        Circle()
                            .fill(entry.color)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 2))
                            .offset(x: x(entry.value) - 5.5, y: 12)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(StrandPalette.hairline)
                    .frame(height: 3)
                    .offset(y: 16)
            }
        }
        .frame(height: 35)
        .accessibilityHidden(true)
    }
}

/// One site's change, drawn either side of a centre line.
///
/// Direction is carried by which way the bar runs, NOT by colour. A growing arm and a shrinking waist
/// are both good news on a recomposition; a growing waist is not; and which is which depends on the
/// site and on what the wearer is training for. Colouring one direction green would make that judgement
/// on their behalf, and get it wrong half the time.
///
/// A change inside the wearer's own tape scatter is drawn muted rather than hidden — it happened, it
/// just cannot be told apart from measurement noise, and hiding it would misrepresent the record.
struct DivergingBar: View {
    let value: Double
    /// The largest absolute change on screen, so every bar shares one scale.
    let scale: Double
    var muted = false

    private var fraction: Double {
        guard scale > 0 else { return 0 }
        return min(abs(value) / scale, 1)
    }

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(width: 1)
                    .offset(x: half)
                RoundedRectangle(cornerRadius: 2)
                    .fill((muted ? StrandPalette.textTertiary : StrandPalette.metricCyan)
                        .opacity(muted ? 0.35 : 0.85))
                    .frame(width: max(2, half * fraction))
                    .offset(x: value < 0 ? half - max(2, half * fraction) : half)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
