#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// One entry: change the amount, the time or the meal, or delete it.
struct FoodEntrySheet: View {
    let entry: FoodLogEntry
    let model: ForgeFoodModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double
    @State private var time: Date
    @State private var meal: FoodLog.MealKind?

    init(entry: FoodLogEntry, model: ForgeFoodModel) {
        self.entry = entry
        self.model = model
        _grams = State(initialValue: entry.grams ?? 0)
        _time = State(initialValue: Date(timeIntervalSince1970: TimeInterval(entry.loggedAt)))
        _meal = State(initialValue: entry.meal.flatMap(FoodLog.MealKind.init(rawValue:)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(entry.name, value: entry.brand ?? "")
                }
                if let per100g = entry.per100g {
                    Section("Amount") {
                        TextField("Grams", value: $grams, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                        LabeledContent("Energy", value: "\(FoodText.kcal(NutrientAmounts(stored: per100g).scaled(toGrams: grams)[.energyKcal])) kcal")
                    }
                }
                Section {
                    ForEach(nutrients, id: \.0) { nutrient, value in
                        LabeledContent {
                            Text(FoodText.amount(value, nutrient))
                        } label: {
                            HStack(spacing: 12) {
                                FoodNutrientBadge(nutrient: nutrient)
                                Text(FoodText.nutrient(nutrient))
                                if entry.estimatedKeys.contains(nutrient.rawValue) || entry.estimatedKeys.contains(FoodEstimate.aiPrefix + nutrient.rawValue) {
                                    Text("estimated").font(.caption).foregroundStyle(ForgeColor.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Nutrients")
                } footer: {
                    Text("For the amount above. Nutrients the source does not state are left out.")
                }
                Section("When") {
                    DatePicker("Time", selection: $time)
                    FoodMealPicker(meal: $meal)
                }
                Section {
                    Button("Delete", role: .destructive, action: delete)
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Every nutrient this entry knows, for the amount being edited, in the nutrient page's order.
    private var nutrients: [(FoodNutrient, Double)] {
        let totals = entry.per100g.map { NutrientAmounts(stored: $0).scaled(toGrams: grams) } ?? NutrientAmounts(stored: entry.totals)
        let order = [FoodNutrient.energyKcal, .proteinG, .carbsG, .fatG] + FoodNutrientReport.groups.flatMap(\.nutrients)
        var seen = Set<FoodNutrient>()
        return order.filter { seen.insert($0).inserted }.compactMap { n in totals[n].map { (n, $0) } }
    }

    private func cancel() { dismiss() }
    private func delete() { Task { await model.delete([entry], repo: repo); dismiss() } }
    private func save() {
        Task {
            await model.update(entry, grams: entry.per100g != nil && grams > 0 ? grams : nil, at: time, meal: meal, repo: repo)
            dismiss()
        }
    }
}
#endif
