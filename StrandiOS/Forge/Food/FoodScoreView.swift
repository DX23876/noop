#if os(iOS)
import SwiftUI
import StrandCore

/// What the week's nutrition score is made of: ten parts, each up to ten points, in everyday words. Highly
/// processed food is shown below on its own, since the index does not count it.
struct FoodScoreView: View {
    let score: FoodScore.Result
    let male: Bool

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text(FoodText.kcal(score.score)).font(ForgeFont.rounded(56, .bold)).foregroundStyle(ForgeColor.text)
                        .monospacedDigit()
                    Text(FoodText.scoreWord(score.score)).font(.headline).foregroundStyle(ForgeColor.secondary)
                    Text("From \(score.loggedDays) logged days of the last 7").font(.footnote).foregroundStyle(ForgeColor.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            } footer: {
                Text("The score follows a healthy eating index from long studies of large groups. It reads what you usually eat, so it looks at a week, not a day.")
            }
            Section("Parts") {
                ForEach(score.parts.sorted { $0.points > $1.points }, id: \.component) { part in
                    row(part)
                }
            }
            if let share = score.processedShare {
                Section {
                    LabeledContent("Highly processed food", value: String(localized: "\(FoodText.percent(share)) of calories"))
                } footer: {
                    Text("Counted on its own, not inside the score. Known only for products that carry a processing class.")
                }
            }
        }
        .navigationTitle("Nutrition score")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ part: FoodScore.Part) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(FoodText.component(part.component)).font(.body).foregroundStyle(ForgeColor.text)
                Spacer()
                Text("\(FoodText.grams(part.points)) / 10").font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(ForgeColor.text)
            }
            // A thin bar like the nutrient card's, so the parts read as one family with the rest of Food.
            Capsule().fill(tint(part.points).opacity(ForgeOpacity.wash))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(tint(part.points)).frame(width: proxy.size.width * min(1, max(0, part.points / 10)))
                    }
                }
            Text("\(FoodText.componentAmount(part)) · \(FoodText.componentGoal(part.component, male: male))")
                .font(.footnote).foregroundStyle(ForgeColor.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func tint(_ points: Double) -> Color {
        points >= 7 ? ForgeColor.nutrientLeaf : points >= 4 ? ForgeColor.nutrientSun : ForgeColor.nutrientRed
    }
}
#endif
