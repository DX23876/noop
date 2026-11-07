import SwiftUI
import StrandDesign

/// A Charge, Effort or Rest score ring in the style the wearer chose (Settings, Motion, Rings): the living
/// `OrganicScoreRing`, or a still classic `GlowRing` drawn from the same visual model. Every score ring goes
/// through here, so the one setting holds everywhere.
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
        if ScoreRingStyle.resolve(styleRaw) == .classic {
            classic
        } else {
            OrganicScoreRing(model: model, tint: tint, score: score, decimals: decimals, frame: frame,
                             diameter: diameter, hitDiameter: hitDiameter, memoKey: memoKey)
        }
    }

    /// The arc sits where the organic contour does, a little inside the ring's square.
    private var classic: some View {
        let ring = diameter * 0.76
        let isCharge = model.metric == .charge
        return Group {
            if let score, let fraction = model.normalizedValue {
                GlowRing(fraction: fraction, value: score, format: format,
                         color: isCharge ? StrandPalette.chargeRingColor(score) : tint,
                         diameter: ring, lineWidth: ring * 0.09,
                         caption: isCharge && namesBand ? StrandPalette.recoveryState(score) : nil)
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
