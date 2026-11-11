#if os(iOS)
import SwiftUI
import StrandCore

/// The Health tab's way into the food log: what today holds so far, the still life of the Food page, and a
/// button straight to the add sheet. It reads only today's log, never the goal: the goal needs the energy plan,
/// which only the Food page resolves, so the card states nothing the page could state differently.
struct FoodHealthCard: View {
    @EnvironmentObject private var repo: Repository
    @State private var summary: FoodLog.DaySummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: ForgeRoute.food) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Nutrition").font(.system(.headline)).foregroundStyle(ForgeColor.text)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                .foregroundStyle(ForgeColor.tertiary)
                        }
                        Text(headline).font(ForgeFont.rounded(20)).foregroundStyle(ForgeColor.text)
                            .contentTransition(.numericText())
                        Text(detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    picture
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

            NavigationLink(value: ForgeRoute.foodAdd) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(ForgeColor.food)
                    Text("Log food").foregroundStyle(ForgeColor.text)
                }
                .font(.system(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(ForgeColor.fill))
            }
            .buttonStyle(.plain)
        }
        .forgeCard(radius: ForgeRadius.card, padding: 14)
        .animation(.smooth, value: summary?.totals[.energyKcal])
        // Runs again whenever the tab shows again, so a meal logged on the Food page is here on the way back.
        .task(id: repo.refreshSeq) {
            guard let store = await repo.storeHandle() else { return }
            summary = await FoodLog.day(store: store, Repository.localDayKey(.now))
        }
    }

    private var logged: Bool { !(summary?.entries.isEmpty ?? true) }

    private var headline: String {
        guard let summary, logged else { return String(localized: "Nothing logged today") }
        return String(localized: "\(FoodText.kcal(summary.totals[.energyKcal] ?? 0)) kcal today")
    }

    private var detail: String {
        guard let totals = summary?.totals, logged else { return String(localized: "Meals, calories and nutrients") }
        return String(localized: "Protein \(FoodText.grams(totals[.proteinG] ?? 0)) g · Carbs \(FoodText.grams(totals[.carbsG] ?? 0)) g · Fat \(FoodText.grams(totals[.fatG] ?? 0)) g")
    }

    /// The right side of the Food page's still life, where the food sits.
    private var picture: some View {
        Image("foodHero")
            .resizable()
            .scaledToFill()
            .frame(width: 76, height: 76, alignment: .trailing)
            .clipShape(.rect(cornerRadius: ForgeRadius.inner))
            .accessibilityHidden(true)
    }
}
#endif
