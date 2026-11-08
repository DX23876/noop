#if os(iOS)
import SwiftUI
import StrandCore

/// The week's nutrition score under the week strip, in a number and a word, leading to what it is made of. Before
/// five logged days it says how far along the week is instead of showing a number.
struct FoodScoreRow: View {
    let score: FoodScore.Result?
    let loggedDays: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "leaf.fill").font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.nutrientLeaf)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(ForgeColor.nutrientLeaf.opacity(ForgeOpacity.wash)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nutrition score").font(.body.weight(.semibold)).foregroundStyle(ForgeColor.text)
                    Text(subtitle).font(.footnote).foregroundStyle(ForgeColor.secondary)
                }
                Spacer(minLength: 8)
                if let score {
                    Text(FoodText.kcal(score.score)).font(ForgeFont.rounded(24, .bold)).foregroundStyle(ForgeColor.text)
                        .monospacedDigit().contentTransition(.numericText())
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ForgeColor.secondary)
            }
            .forgeCard(padding: 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.smooth, value: score?.score)
    }

    private var subtitle: String {
        if let score { return String(localized: "\(FoodText.scoreWord(score.score)) · last 7 days") }
        return String(localized: "Shows after 5 logged days · \(loggedDays) of 7 so far")
    }
}
#endif
