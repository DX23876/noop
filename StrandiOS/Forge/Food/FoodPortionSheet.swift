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

    /// The amounts offered, from the core (`FoodPortions`), so both platforms offer the same ones.
    private var presets: [(label: String, grams: Double, names: Bool)] {
        FoodPortions.options(for: item, lastAmount: lastGrams).map { option in
            (Self.label(option, item: item), option.amount, Self.names(option.kind))
        }
    }

    /// Millilitres for a drink, grams for everything else. The nutrients of a drink are stated per 100 ml, so
    /// the number is used as it is.
    static func label(_ option: FoodPortions.Option, item: FoodItem) -> String {
        let unit = item.liquid == true ? "ml" : "g"
        let amount = "\(FoodText.grams(option.amount)) \(unit)"
        switch option.kind {
        case .serving(let label):
            if let label { return String(localized: "1 portion (\(label))") }
            let number = FoodText.grams(option.amount)
            return item.liquid == true ? String(localized: "1 portion (\(number) ml)") : String(localized: "1 portion (\(number) g)")
        case .lastTime:
            let number = FoodText.grams(option.amount)
            return item.liquid == true ? String(localized: "Last time \(number) ml") : String(localized: "Last time \(number) g")
        case .piece(let count):
            return String(localized: "1 of \(count) (\(amount))")
        case .halfPack:
            return String(localized: "Half a pack (\(amount))")
        case .wholePack(let count):
            guard count > 1, let one = item.packageAmount else { return String(localized: "Whole pack (\(amount))") }
            return String(localized: "Whole pack (\(count) × \(FoodText.grams(one)) \(unit))")
        case .amount:
            return amount
        }
    }

    /// Whether the option's name is worth keeping on the entry ("1 of 6 (330 ml)"), rather than only its amount.
    static func names(_ kind: FoodPortions.Kind) -> Bool {
        switch kind {
        case .serving, .piece, .halfPack, .wholePack: return true
        case .lastTime, .amount: return false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(item.name, value: item.brand ?? "")
                }
                Section("Amount") {
                    TextField(item.liquid == true ? "Millilitres" : "Grams", value: $grams,
                              format: .number.precision(.fractionLength(0...1))).keyboardType(.decimalPad)
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
        // A named choice keeps its name ("1 of 6 (330 ml)"); a drink typed in by hand keeps its millilitres, since
        // the entry rows would otherwise read it as grams.
        let named = presets.first { $0.names && abs($0.grams - grams) < 0.01 }?.label
        let label = named ?? (item.liquid == true ? "\(FoodText.grams(grams)) ml" : nil)
        add(FoodCartLine(item: item, grams: grams, portionLabel: label))
        dismiss()
    }
}
#endif
