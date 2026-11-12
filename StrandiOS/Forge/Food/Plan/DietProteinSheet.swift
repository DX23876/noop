#if os(iOS)
import SwiftUI
import StrandCore

/// Where more protein comes from (owner, 2026-11-10), opened by the protein suggestion: the plan's own goal beside
/// last week's mean, so the figure matches the plan page, and the food groups richest in protein with an everyday
/// portion. Groups the wearer's plan leaves out (vegetarian, vegan) are not offered.
struct DietProteinSheet: View {
    let goalG: Double
    let meanG: Double?
    let addon: DietAddon?
    @Environment(\.dismiss) private var dismiss

    /// The groups and a portion's protein, shared with Android (`DietProteinSources`).
    private var groups: [(FoodGroupMotif, Int)] {
        DietProteinSources.groups(addon: addon).map { ($0.group, $0.grams) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your plan: \(Int(goalG.rounded())) g a day").font(.title3.weight(.semibold)).foregroundStyle(ForgeColor.text)
                        if let meanG {
                            Text("Last week on average \(Int(meanG.rounded())) g, about \(Int(max(0, goalG - meanG).rounded())) g short.")
                                .font(.subheadline).foregroundStyle(ForgeColor.secondary)
                            // A portion from the list brings about 30 g.
                            let portions = DietProteinSources.portionsToClose(goalG: goalG, meanG: meanG)
                            if portions > 0 {
                                Text(portions == 1 ? String(localized: "One more portion from this list a day closes it.")
                                                   : String(localized: "About \(portions) more portions from this list a day close it."))
                                    .font(.subheadline).foregroundStyle(ForgeColor.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .forgeCard(padding: 14)
                    VStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                            HStack(spacing: 12) {
                                Image(FoodMealPicture.assetName(g.0)).resizable().scaledToFill()
                                    .frame(width: 56, height: 44).clipShape(.rect(cornerRadius: 10))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(FoodText.motif(g.0)).font(.headline).foregroundStyle(ForgeColor.text)
                                    Text(portion(g.0)).font(.footnote).foregroundStyle(ForgeColor.secondary)
                                }
                                Spacer(minLength: 8)
                                Text("\(g.1) g").font(.headline).monospacedDigit().foregroundStyle(ForgeColor.text)
                            }
                            .padding(.vertical, 10)
                            .accessibilityElement(children: .combine)
                            if i < groups.count - 1 { Divider() }
                        }
                    }
                    .forgeCard(padding: 14)
                    Text("Protein per everyday portion, rounded from common food tables.")
                        .font(.footnote).foregroundStyle(ForgeColor.secondary)
                }
                .padding(16)
            }
            .background(ForgeBackground(tab: .today))
            .navigationTitle("More protein")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func portion(_ m: FoodGroupMotif) -> String {
        switch m {
        case .poultry: String(localized: "A chicken or turkey breast, 150 g")
        case .meat: String(localized: "Lean beef or pork, 150 g")
        case .fish: String(localized: "A fillet of fish, 150 g")
        case .dairy: String(localized: "Skyr, quark or cottage cheese, 250 g")
        case .legumes: String(localized: "Cooked lentils, beans or chickpeas, 200 g")
        case .eggs: String(localized: "Two eggs")
        default: ""
        }
    }
}
#endif
