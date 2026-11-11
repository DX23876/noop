#if os(iOS)
import SwiftUI
import StrandCore

/// "As usual": a meal eaten on several of the last days, offered again at its time of day. Quieter than a logged
/// meal, so it reads as a suggestion; one tap adds it, the other hides it for today.
struct FoodHabitCard: View {
    let habit: FoodRepeat.Suggestion
    let picture: FoodMealPicture.Source?
    let add: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let picture {
                FoodMealPicture(source: picture, height: 56).frame(width: 56)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("As usual · \(FoodText.meal(habit.kind))").font(.footnote).foregroundStyle(ForgeColor.secondary)
                Text(names).font(.body).foregroundStyle(ForgeColor.text).lineLimit(2)
                Text("\(FoodText.kcal(kcal)) kcal").font(.footnote).foregroundStyle(ForgeColor.secondary)
            }
            Spacer(minLength: 8)
            Button("Add", systemImage: "plus.circle.fill", action: add)
                .labelStyle(.iconOnly).font(.title2).tint(ForgeColor.food)
                .frame(minWidth: 44, minHeight: 44)
            Button("Not today", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly).font(.footnote.weight(.semibold)).tint(ForgeColor.secondary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .forgeCard(padding: 12)
        .opacity(0.86)
        .accessibilityElement(children: .contain)
    }

    /// The foods by their short names ("Haferflocken, Vollmilch").
    private var names: String {
        habit.entries.map { $0.name.components(separatedBy: ", ").first ?? $0.name }.joined(separator: ", ")
    }

    private var kcal: Double { habit.entries.reduce(0) { $0 + ($1.totals["energy_kcal"] ?? 0) } }
}
#endif
