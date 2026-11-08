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
                // A still life of a balanced week behind the number; the food sits right, the number on the calm left.
                ZStack(alignment: .leading) {
                    Image("foodScoreHero").resizable().scaledToFill()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .frame(height: 200)
                        .clipped()
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(FoodText.kcal(score.score)).font(ForgeFont.rounded(56, .bold)).foregroundStyle(ForgeColor.onDarkPhoto)
                            .monospacedDigit()
                        Text(FoodText.scoreWord(score.score)).font(.headline).foregroundStyle(ForgeColor.onDarkPhoto)
                        Text("From \(score.loggedDays) logged days of the last 7").font(.footnote).foregroundStyle(ForgeColor.onDarkPhotoSecondary)
                    }
                    // The calm left part of the photo only, so the words never run over the food.
                    .frame(maxWidth: 150, alignment: .leading)
                    .padding(.leading, 20)
                    .accessibilityElement(children: .combine)
                }
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("The score follows a healthy eating index from long studies of large groups. It reads what you usually eat, so it looks at a week, not a day.")
            }
            // Like a ledger: what adds to the score grows right of the middle line, what costs points grows left.
            Section {
                ForEach(score.parts.filter { !$0.component.isLimit }.sorted { $0.points > $1.points }, id: \.component) { part in
                    row(part)
                }
            } header: {
                Text("Adds points")
            }
            Section {
                ForEach(score.parts.filter(\.component.isLimit).sorted { $0.points < $1.points }, id: \.component) { part in
                    row(part)
                }
            } header: {
                Text("Costs points")
            } footer: {
                Text("These start at full points and lose them as the amount rises.")
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
        HStack(alignment: .top, spacing: 12) {
            Image(Self.thumbnail(part.component)).resizable().scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityHidden(true)
            details(part)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// A small still life for each part, from the meal pictures where one fits.
    static func thumbnail(_ c: FoodScore.Component) -> String {
        switch c {
        case .vegetables: "foodMotif_vegetables"
        case .fruit: "foodMotif_fruit"
        case .wholeGrains: "foodMotif_grains"
        case .sugaryDrinks: "foodMotif_drinks"
        case .nutsLegumes: "foodMotif_legumes"
        case .redMeat: "foodMotif_meat"
        case .fishOmega3: "foodMotif_fish"
        case .polyFats: "foodMotif_fats"
        case .sodium: "foodMotif_salt"
        case .alcohol: "foodMotif_alcohol"
        }
    }

    private func details(_ part: FoodScore.Part) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(FoodText.component(part.component)).font(.body).foregroundStyle(ForgeColor.text)
                Spacer()
                Text(signed(part)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(abs(effect(part)) < 0.05 ? ForgeColor.secondary : effect(part) > 0 ? ForgeColor.nutrientLeaf : ForgeColor.nutrientRed)
            }
            FoodScoreBar(effect: effect(part))

            Text("\(FoodText.componentAmount(part)) · \(FoodText.componentGoal(part.component, male: male))")
                .font(.footnote).foregroundStyle(ForgeColor.secondary)
        }
    }

    /// Points added (a part to have more of) or lost (a part to keep low), from -10 to +10.
    private func effect(_ part: FoodScore.Part) -> Double {
        part.component.isLimit ? -(10 - part.points) : part.points
    }

    private func signed(_ part: FoodScore.Part) -> String {
        let e = effect(part)
        guard abs(e) >= 0.05 else { return "0" }
        return (e > 0 ? "+" : "−") + FoodText.grams(abs(e))
    }
}
#endif
