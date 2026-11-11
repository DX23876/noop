#if os(iOS)
import SwiftUI
import StrandCore

/// How much of one food: grams, its portion, the last amount or a round amount, with the nutrients live.
struct FoodPortionSheet: View {
    let item: FoodItem
    var lastGrams: Double?
    let add: (FoodCartLine) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double

    init(item: FoodItem, lastGrams: Double?, add: @escaping (FoodCartLine) -> Void) {
        self.item = item
        self.lastGrams = lastGrams
        self.add = add
        _grams = State(initialValue: lastGrams ?? item.servingG ?? 100)
    }

    private var presets: [(label: String, grams: Double)] {
        var out: [(String, Double)] = []
        if let serving = item.servingG {
            out.append((item.servingLabel.map { String(localized: "1 portion (\($0))") }
                        ?? String(localized: "1 portion (\(FoodText.grams(serving)) g)"), serving))
        }
        if let lastGrams, lastGrams != item.servingG { out.append((String(localized: "Last time \(FoodText.grams(lastGrams)) g"), lastGrams)) }
        out += [("50 g", 50), ("100 g", 100), ("250 g", 250)]
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(item.name, value: item.brand ?? "")
                }
                Section("Amount") {
                    TextField("Grams", value: $grams, format: .number.precision(.fractionLength(0...1))).keyboardType(.decimalPad)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(presets, id: \.label) { preset in
                                FoodPresetChip(title: preset.label, selected: abs(grams - preset.grams) < 0.01) { grams = preset.grams }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                Section("Nutrients") {
                    let totals = item.per100g.scaled(toGrams: grams)
                    ForEach([FoodNutrient.energyKcal, .proteinG, .carbsG, .fatG, .fiberG, .sugarG, .saltG], id: \.self) { n in
                        LabeledContent(FoodText.nutrient(n), value: totals[n].map { FoodText.amount($0, n) } ?? String(localized: "not known"))
                    }
                }
                Section {
                    if let note = FoodText.estimateNote(item) { Text(note) }
                    Text(sourceNote)
                }
                .font(.footnote).foregroundStyle(ForgeColor.secondary)
            }
            .navigationTitle("Amount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: confirm).disabled(!(grams > 0 && grams <= 10_000)) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sourceNote: String {
        switch item.source {
        case .bls: String(localized: "Source: German Nutrient Database (BLS 4.0), Max Rubner-Institut, CC BY 4.0.")
        case .off, .online: String(localized: "Source: Open Food Facts, ODbL. Values are entered by volunteers and can be wrong.")
        case .own: String(localized: "Your own food.")
        case .recipe: String(localized: "Your recipe, per 100 g of the whole dish.")
        }
    }

    private func cancel() { dismiss() }
    private func confirm() {
        let label = item.servingG.flatMap { abs($0 - grams) < 0.01 ? item.servingLabel ?? String(localized: "1 portion") : nil }
        add(FoodCartLine(item: item, grams: grams, portionLabel: label))
        dismiss()
    }
}
#endif
