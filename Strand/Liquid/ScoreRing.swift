import SwiftUI
import StrandDesign

/// A Charge, Effort or Rest score ring in the style the wearer chose (Settings, Style, Rings): the living
/// `OrganicScoreRing`, a still classic `GlowRing`, or a flat coloured `FlatScoreRing`, the last two drawn from
/// the same visual model. Every score ring goes through here, so the one setting holds everywhere.
struct ScoreRing: View {
    let model: OrganicScoreVisualModel
    let tint: Color
    let score: Double?
    let decimals: Int
    let frame: OrganicScoreFrame
    var diameter: CGFloat = 104
    var hitDiameter: CGFloat? = nil
    var memoKey: String? = nil
    /// Whether the classic Charge ring names its band inside. A page that names it under the ring passes
    /// false, so the word is not shown twice.
    var namesBand = true

    @AppStorage(ScoreRingStyle.storageKey) private var styleRaw = ScoreRingStyle.defaultStyle.rawValue

    var body: some View {
        switch ScoreRingStyle.resolve(styleRaw) {
        case .organic:
            OrganicScoreRing(model: model, tint: tint, score: score, decimals: decimals, frame: frame,
                             diameter: diameter, hitDiameter: hitDiameter, memoKey: memoKey)
        case .classic:
            classic
        case .colored:
            colored
        }
    }

    /// Flat and in fixed colours: the caller's tint is not used, so every page draws one score in one colour.
    /// Charge and Rest are percentages and say so; Effort is a load, on either scale, and carries no sign.
    private var colored: some View {
        let ring = diameter * 0.76
        let color = StrandPalette.coloredRingTint(metric: model.metric, score: score)
        let unit = model.metric == .effort ? nil : "%"
        return Group {
            if let score, let fraction = model.normalizedValue {
                FlatScoreRing(fraction: fraction, value: score, format: format, color: color,
                              diameter: ring, lineWidth: ring * 0.075, unit: unit)
            } else {
                FlatScoreRing(fraction: 0, value: 0, format: { _ in "–" }, color: color,
                              diameter: ring, lineWidth: ring * 0.075)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle().inset(by: max(0, (diameter - (hitDiameter ?? diameter)) / 2)))
    }

    /// The arc sits where the organic contour does, a little inside the ring's square.
    private var classic: some View {
        let ring = diameter * 0.76
        // The shipped design colours Charge by its band and names the band inside. The new design keeps
        // Charge in its one colour everywhere, as the living ring does, and names the band under the ring.
        let bandCharge = model.metric == .charge && NoopVisualStyle.skin != .forge
        return Group {
            if let score, let fraction = model.normalizedValue {
                GlowRing(fraction: fraction, value: score, format: format,
                         color: bandCharge ? StrandPalette.chargeRingColor(score) : tint,
                         diameter: ring, lineWidth: ring * 0.09,
                         caption: bandCharge && namesBand ? StrandPalette.recoveryState(score) : nil)
            } else {
                GlowRing(fraction: 0, value: 0, format: { _ in "–" }, color: tint,
                         diameter: ring, lineWidth: ring * 0.09)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle().inset(by: max(0, (diameter - (hitDiameter ?? diameter)) / 2)))
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).locale(AppLanguage.activeLocale))
    }
}
