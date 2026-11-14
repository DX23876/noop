#if os(iOS)
import SwiftUI
import StrandCore

/// How much of one food: grams, its portion, the last amount or a round amount, with the nutrients live.
struct FoodPortionSheet: View {
    let model: ForgeFoodModel
    var lastGrams: Double?
    let add: (FoodCartLine) -> Void
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double
    /// The product as it stands: a correction made here replaces it, and the amount keeps its own figure.
    @State private var item: FoodItem
    @State private var correcting = false

    init(item: FoodItem, model: ForgeFoodModel, lastGrams: Double?, add: @escaping (FoodCartLine) -> Void) {
        self.model = model
        self.lastGrams = lastGrams
        self.add = add
        _item = State(initialValue: item)
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
                    Button(action: correct) {
                        HStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3").foregroundStyle(ForgeColor.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Check values").foregroundStyle(ForgeColor.text)
                                if let warning { Text(warning).font(.footnote).foregroundStyle(ForgeColor.effortInk) }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(ForgeColor.tertiary)
                        }
                    }
                }
                Section {
                    if let note = FoodText.estimateNote(item) { Text(note) }
                    Text(FoodText.sourceNote(item))
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
        .sheet(isPresented: $correcting) {
            FoodProductEditSheet(item: item, model: model) { item = $0 }
                .environmentObject(repo)
        }
    }

    /// What the energy figure and the nutrients say about each other, from the one check in the core; nil when
    /// they agree or when the nutrients cannot give an answer.
    private var warning: String? {
        guard let check = FoodEnergy.check(item.per100g) else { return nil }
        if check.isMissing { return String(localized: "Energy worked out from the nutrients") }
        return check.disagrees ? String(localized: "The stated energy does not fit the nutrients") : nil
    }

    private func correct() { correcting = true }

    private func cancel() { dismiss() }
    private func confirm() {
        let label = item.servingG.flatMap { abs($0 - grams) < 0.01 ? item.servingLabel ?? String(localized: "1 portion") : nil }
        add(FoodCartLine(item: item, grams: grams, portionLabel: label))
        dismiss()
    }
}
#endif
