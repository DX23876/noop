import SwiftUI
import StrandDesign

// MARK: - Drei Ringe (docs/feature-spec.md §2 references Charge/Effort/Rest; docs/design/design-spec.md §2)
//
// Three `GlowRing`s (StrandDesign, reused as-is — not rebuilt) side by side, on a fixed-colour tile with
// a soft radial glow behind it. Colours come from `HeuteRedesignPalette`, NOT `StrandPalette.chargeColor`
// et al. — those are chart-style-dependent and would drift off the mockup's fixed green/blue/violet on
// any style other than `.signature` (see HeuteRedesignPalette's doc comment).

struct HeuteRingsView: View {
    /// 0...100, or nil for the honest empty state (no scored night, no prior to carry). A nil Charge
    /// draws NO number — `chargeEmptyLabel` names why — rather than a fabricated 0%, matching how the
    /// other two Today screens render `.calibrating` / `.noData`.
    let charge: Double?
    /// The short word shown in place of the Charge number when `charge` is nil ("Calibrating" / "No data").
    var chargeEmptyLabel: String? = nil
    /// Always the stored NOOP 0...100 axis (`DailyMetric.strain`) — never pre-converted. `effortScale`
    /// decides only how it's DISPLAYED (the fraction filled is scale-invariant: it's always effort/100).
    let effort: Double
    let rest: Double     // 0...100
    var effortScale: EffortScale = .hundred
    /// Tapping the Charge ring opens its breakdown sheet (why the value is what it is). Only Charge is
    /// tappable — Effort/Rest stay pure display, matching the chosen scope (the other two Today screens'
    /// Charge-ring tap). Fires for BOTH the filled and the empty ring: a calibrating/no-data ring should
    /// still explain why it has no number.
    var onChargeTap: (() -> Void)? = nil

    private let diameter: CGFloat = 92
    private let lineWidth: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            chargeRing
                // The canvas/labels leave gaps; `contentShape` makes the whole ring column a tap target so
                // a tap between the arc strokes still opens the breakdown instead of falling through.
                .contentShape(Rectangle())
                .onTapGesture { onChargeTap?() }
            Spacer(minLength: 0)
            // Was hardcoded to `effort / 21` (the WHOOP display scale) while being fed the stored NOOP
            // 0-100 value — a real strain of e.g. 65 rendered as 65/21 ≈ 310%, clamped to a full ring.
            // Every other screen reads the user's EffortScale setting (Strand/Data/Units.swift,
            // @AppStorage(UnitPrefs.effortScaleKey)) for exactly this; this ring now does too — the
            // ROLLING NUMBER converts via `UnitFormatter.effortValue`, the fill fraction stays effort/100
            // regardless of scale (the proportion doesn't change, only what number labels it).
            ring(fraction: effort / 100, value: UnitFormatter.effortValue(effort, scale: effortScale),
                 suffix: nil, color: HeuteRedesignPalette.effort, label: "Effort")
            Spacer(minLength: 0)
            ring(fraction: rest / 100, value: rest, suffix: "%", color: HeuteRedesignPalette.rest, label: "Rest")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(HeuteRedesignPalette.tile)
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
        }
        .background(glow)
    }

    /// design-spec §2: "sanfter Glow dahinter... reicht ca. 18pt über den Container hinaus" — a radial
    /// gradient in the Charge colour at ~16% opacity, sized past the tile's own bounds.
    private var glow: some View {
        RadialGradient(colors: [HeuteRedesignPalette.charge.opacity(0.16), .clear],
                        center: .center, startRadius: 0, endRadius: diameter * 1.6)
            .padding(-18)
            .allowsHitTesting(false)
    }

    /// The Charge ring, which unlike Effort/Rest has an honest EMPTY state (a night either scored or it
    /// didn't). A value fills the ring as usual; nil draws no arc and no number, only the empty-state word
    /// ("Calibrating" / "No data") in the same house numeral size as a filled ring, so the trio stays
    /// visually level regardless of state.
    @ViewBuilder private var chargeRing: some View {
        if let charge {
            ring(fraction: charge / 100, value: charge, suffix: "%",
                 color: HeuteRedesignPalette.charge, label: "Charge")
        } else {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(HeuteRedesignPalette.line, lineWidth: lineWidth)
                        .frame(width: diameter, height: diameter)
                    Text(chargeEmptyLabel ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(HeuteRedesignPalette.ink3)
                        .frame(width: diameter - lineWidth * 2)
                }
                Text("Charge")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.9)
                    .textCase(.uppercase)
                    .foregroundStyle(HeuteRedesignPalette.ink3)
            }
        }
    }

    private func ring(fraction: Double, value: Double, suffix: String?, color: Color, label: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            ZStack {
                GlowRing(fraction: fraction, value: value,
                         format: { suffix == nil ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" },
                         color: color, diameter: diameter, lineWidth: lineWidth)
                if let suffix {
                    Text(suffix)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HeuteRedesignPalette.ink3)
                        .offset(x: diameter * 0.30, y: diameter * 0.10)
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(HeuteRedesignPalette.ink3)
        }
    }
}
