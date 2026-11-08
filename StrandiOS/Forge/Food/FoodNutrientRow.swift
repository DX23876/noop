#if os(iOS)
import SwiftUI
import StrandCore

/// One nutrient: the week's average, a bullet bar with the reference marked, its status in a symbol and in words,
/// and on a tap the foods it mostly came from.
struct FoodNutrientRow: View {
    let row: FoodNutrientReport.Row
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(FoodText.nutrient(row.nutrient), systemImage: symbol)
                            .labelStyle(FoodStatusLabelStyle(tint: tint))
                        Spacer()
                        Text(FoodText.amount(row.average, row.nutrient)).font(.subheadline).bold().foregroundStyle(ForgeColor.text)
                    }
                    if let reference = row.reference {
                        // The scale runs to one and a half times the reference, so the mark sits at two thirds.
                        let scale = max(reference.amount * 1.5, row.average)
                        FoodShareBar(share: row.average / max(0.0001, scale), tint: tint, reference: reference.amount / max(0.0001, scale))
                        Text(caption(reference)).font(.footnote).foregroundStyle(ForgeColor.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded, !row.topFoods.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mostly from").font(.caption).bold().foregroundStyle(ForgeColor.secondary)
                    ForEach(row.topFoods, id: \.name) { source in
                        LabeledContent(source.name, value: FoodText.amount(source.amount, row.nutrient)).font(.footnote)
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch row.status {
        case .fine: ForgeColor.charge
        case .attention: ForgeColor.effort
        default: ForgeColor.tertiary
        }
    }

    private var symbol: String {
        switch row.status {
        case .fine: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .incomplete: "questionmark.circle"
        case .mostlyModel: "sparkles"
        case .none: "circle"
        }
    }

    private func caption(_ reference: FoodReference.Value) -> String {
        switch row.status {
        case .incomplete:
            return String(localized: "Not enough data: only \(FoodText.percent(row.coverage)) of what you logged states it.")
        case .mostlyModel:
            return String(localized: "Mostly your coach's estimate, so it is not rated.")
        default:
            let ref = FoodText.amount(reference.amount, row.nutrient)
            var text = reference.kind == .atLeast ? String(localized: "Reference \(ref) a day (\(reference.source))")
                                                  : String(localized: "Limit \(ref) a day (\(reference.source))")
            let estimated = row.estimatedShare + row.modelShare
            if estimated >= 0.05 { text += " · " + String(localized: "\(FoodText.percent(estimated)) estimated") }
            return text
        }
    }

    private func toggle() { withAnimation(reduceMotion ? nil : .smooth) { expanded.toggle() } }
}
#endif
