#if os(iOS)
import SwiftUI

/// The note as a ring that fills to 10, in a colour that says how good it is, the note itself inside.
struct FoodQualityRing: View {
    let score: Double?
    var size: CGFloat = 88

    var body: some View {
        ZStack {
            Circle().stroke(ForgeColor.fill, lineWidth: size * 0.1)
            Circle().trim(from: 0, to: min(1, (score ?? 0) / 10))
                .stroke(Self.tint(score), style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(score.map(FoodText.note) ?? "–")
                    .font(ForgeFont.rounded(size * 0.3, .bold)).foregroundStyle(ForgeColor.text)
                    .monospacedDigit().contentTransition(.numericText())
                Text(verbatim: "/ 10").font(.caption2).foregroundStyle(ForgeColor.secondary)
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth, value: score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(score.map { "\(FoodText.note($0)) / 10, \(FoodText.noteWord($0))" } ?? "–"))
    }

    /// Green from 7.5, yellow from 5.5, orange below: the colour says the word before it is read.
    static func tint(_ score: Double?) -> Color {
        guard let score else { return ForgeColor.secondary }
        if score >= 7.5 { return ForgeColor.nutrientLeaf }
        if score >= 5.5 { return ForgeColor.nutrientSun }
        return ForgeColor.effort
    }
}
#endif
