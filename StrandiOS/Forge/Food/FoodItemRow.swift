#if os(iOS)
import SwiftUI
import StrandCore

/// One food to pick (redesign 2026-11-21): the group's picture, name and what it brings per 100 g, a star that shows
/// and changes whether it is a favourite, and, when it was eaten before, its last amount as a one-tap add. Tapping
/// the row itself opens the amount.
struct FoodItemRow: View {
    let item: FoodItem
    let lastGrams: Double?
    var isFavourite = false
    let onPick: (FoodItem) -> Void
    let onFavourite: (FoodItem, Bool) -> Void
    /// Adds the food with its last amount straight to the cart; nil hides the shortcut.
    var onQuickAdd: ((FoodItem, Double) -> Void)? = nil
    /// The diet plan, so a food that suits it carries a small leaf. Nothing is hidden or forbidden.
    @AppStorage(DietPlan.storageKey) private var planRaw = ""

    var body: some View {
        HStack(spacing: 12) {
            Button(action: pick) {
                HStack(spacing: 12) {
                    FoodThumbnail(motif: motif)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text).lineLimit(2)
                        HStack(spacing: 4) {
                            if fitsPlan {
                                Image(systemName: "leaf.fill").foregroundStyle(ForgeColor.nutrientLeaf)
                                    .accessibilityLabel(Text("Suits your plan"))
                            }
                            Text(detail).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                        }
                        .font(ForgeFont.caption)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Choose the amount"))
            Button(isFavourite ? "Remove from favourites" : "Add to favourites",
                   systemImage: isFavourite ? "star.fill" : "star", action: toggleFavourite)
                .labelStyle(.iconOnly)
                .font(.body)
                .foregroundStyle(isFavourite ? ForgeColor.fat : ForgeColor.tertiary)
                .frame(width: 32, height: 44)
                .buttonStyle(.plain)
                .contentTransition(.symbolEffect(.replace))
                .sensoryFeedback(.selection, trigger: isFavourite)
            if let quickAmount, let onQuickAdd {
                Button { onQuickAdd(item, quickAmount) } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: "\(FoodText.grams(quickAmount)) \(unit)").monospacedDigit()
                        Image(systemName: "plus").fontWeight(.bold)
                    }
                    .font(ForgeFont.caption.weight(.semibold))
                    .foregroundStyle(ForgeColor.food)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(ForgeColor.fill, in: .capsule)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Add \(FoodText.grams(quickAmount)) \(unit)"))
            } else {
                Button("Choose the amount", systemImage: "plus.circle.fill", action: pick)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(ForgeColor.food)
                    .frame(width: 44, height: 44)
                    .buttonStyle(.plain)
            }
        }
    }

    /// The amount the plus adds in one tap: what the wearer had last time, else the product's own stated portion
    /// (owner, 2026-11-25, as YAZIO and FDDB do). A food with neither opens the amount sheet instead.
    private var quickAmount: Double? { lastGrams ?? item.servingG }
    private var unit: String { item.liquid == true ? "ml" : "g" }

    /// The cart line for a one-tap add: the stated portion keeps its name, a drink its millilitres.
    static func quickLine(_ item: FoodItem, _ amount: Double) -> FoodCartLine {
        let serving = item.servingG.map { abs($0 - amount) < 0.01 } == true
        let named = serving ? item.servingLabel.map { String(localized: "1 portion (\($0))") } : nil
        let drink = item.liquid == true ? "\(FoodText.grams(amount)) ml" : nil
        return FoodCartLine(item: item, grams: amount, portionLabel: named ?? drink)
    }

    private var motif: FoodGroupMotif? { FoodGroupMotif.forFoodId(item.id) ?? FoodGroupMotif.forGroup(item.group) }

    private var fitsPlan: Bool {
        guard let plan = DietPlan.decode(planRaw), let motif else { return false }
        return plan.form.fit(motif, addon: plan.addon) > 0
    }

    /// Brand and energy only: the amount sits on its own button, and where the food comes from is a detail the
    /// food's own sheet shows.
    private var detail: String {
        var parts = ["\(FoodText.kcal(item.per100g[.energyKcal])) kcal / 100 g"]
        if let brand = item.brand { parts.insert(brand, at: 0) }
        switch item.source {
        case .own: parts.append(String(localized: "yours"))
        case .recipe: parts.append(String(localized: "recipe"))
        case .bls, .off, .online: break
        }
        return parts.joined(separator: " · ")
    }

    private func pick() { onPick(item) }
    private func toggleFavourite() { onFavourite(item, !isFavourite) }
}
#endif
