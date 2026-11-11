#if os(iOS)
import SwiftUI
import StrandCore

/// One nutrient: the average against the recommended amount, a thin bar, and on a tap the foods it mostly came from.
struct FoodNutrientRow: View {
    let row: FoodNutrientReport.Row
    var pinned = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    FoodNutrientBadge(nutrient: row.nutrient)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(FoodText.nutrient(row.nutrient)).font(ForgeFont.body).foregroundStyle(ForgeColor.text)
                            if pinned {
                                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(ForgeColor.tertiary)
                                    .accessibilityLabel(Text("Pinned"))
                            }
                            if row.status == .attention {
                                Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(ForgeColor.effort)
                            }
                            Spacer()
                            Text(FoodText.amount(row.average, row.nutrient)).font(.subheadline).bold().foregroundStyle(ForgeColor.text)
                            if let reference = row.reference {
                                Text(reference.kind == .atLeast ? "of \(FoodText.amount(reference.amount, row.nutrient))"
                                                                : "max \(FoodText.amount(reference.amount, row.nutrient))")
                                    .font(.footnote).foregroundStyle(ForgeColor.secondary)
                            }
                        }
                        if let reference = row.reference {
                            let scale = max(reference.amount, row.average)
                            FoodShareBar(share: row.average / max(0.0001, scale), tint: tint, height: 4)
                        }
                        if let note {
                            Text(note).font(.caption).foregroundStyle(ForgeColor.secondary)
                        }
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
                .padding(.leading, 44)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(statusWord))
    }

    /// The nutrient's own colour; amber when it is outside what is recommended, grey when it cannot be judged.
    private var tint: Color {
        switch row.status {
        case .attention: ForgeColor.effort
        case .incomplete, .mostlyModel: ForgeColor.tertiary
        default: FoodNutrientBadge.tint(row.nutrient)
        }
    }

    private var statusWord: String {
        switch row.status {
        case .fine: String(localized: "In range")
        case .attention: row.reference?.kind == .atMost ? String(localized: "Above the recommendation") : String(localized: "Below the recommendation")
        case .incomplete: String(localized: "Not enough data")
        case .mostlyModel: String(localized: "Estimated")
        case .none: String(localized: "No recommendation")
        }
    }

    /// Said only when the figure cannot be read at face value.
    private var note: String? {
        switch row.status {
        case .incomplete: return String(localized: "Too few of your foods state it.")
        case .mostlyModel: return String(localized: "Mostly estimated by your coach.")
        default:
            let estimated = row.estimatedShare + row.modelShare
            return estimated >= 0.25 ? String(localized: "\(FoodText.percent(estimated)) estimated") : nil
        }
    }

    private func toggle() { withAnimation(reduceMotion ? nil : .smooth) { expanded.toggle() } }
}
#endif
