#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// The meal builder (2026-11-21): a kept meal made from scratch or changed later. A name, the foods with their
/// amounts, what they bring together, and one save. Each food stays itself, so logging the meal adds one entry per
/// food and every nutrient and food group counts as the food it is.
struct FoodMealEditor: View {
    /// What the builder opens on: a new meal, or one already kept.
    enum Target: Identifiable {
        case new
        case edit(FoodSavedMeal)
        var id: String {
            switch self {
            case .new: "new"
            case .edit(let meal): meal.id
            }
        }
    }

    /// One food of the draft, with an id of its own so two rows of the same food stay apart.
    struct Line: Identifiable {
        let id = UUID()
        var item: FoodRecipe.Item
    }

    let model: ForgeFoodModel
    let target: Target
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var lines: [Line]
    @State private var picking = false
    @State private var saving = false

    init(model: ForgeFoodModel, target: Target) {
        self.model = model
        self.target = target
        switch target {
        case .new:
            // The meal of the hour as a start, so a quick build needs no typing; renaming is one tap away.
            _name = State(initialValue: FoodText.meal(FoodLog.MealKind.around(.now)))
            _lines = State(initialValue: [])
        case .edit(let meal):
            _name = State(initialValue: meal.name)
            _lines = State(initialValue: meal.items.map { Line(item: $0) })
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .font(ForgeFont.cardTitle)
                        .submitLabel(.done)
                }
                Section {
                    ForEach($lines) { $line in
                        FoodMealEditorRow(item: $line.item)
                    }
                    .onDelete(perform: remove)
                    Button("Add a food", systemImage: "plus.circle.fill", action: pick)
                        .foregroundStyle(ForgeColor.food)
                } header: {
                    Text("Foods")
                } footer: {
                    if !lines.isEmpty {
                        Text("Together \(FoodText.kcal(kcal)) kcal · \(FoodText.grams(protein)) g protein")
                            .monospacedDigit()
                    }
                }
                if case .edit(let meal) = target {
                    Section {
                        Button("Delete meal", systemImage: "trash", role: .destructive) { delete(meal) }
                            .foregroundStyle(ForgeColor.nutrientRed)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? String(localized: "New meal") : String(localized: "Edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave || saving)
                }
            }
            .sheet(isPresented: $picking) { FoodPickSheet(model: model, add: add).environmentObject(repo) }
            .sensoryFeedback(.increase, trigger: lines.count)
        }
        .tint(ForgeColor.accent)
    }

    private var isNew: Bool { if case .new = target { true } else { false } }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lines.contains { $0.item.grams > 0 }
    }
    private var kcal: Double { lines.reduce(0) { $0 + ($1.item.per100g["energy_kcal"] ?? 0) * $1.item.grams / 100 } }
    private var protein: Double { lines.reduce(0) { $0 + ($1.item.per100g["protein_g"] ?? 0) * $1.item.grams / 100 } }

    private func close() { dismiss() }
    private func pick() { picking = true }
    private func remove(_ offsets: IndexSet) { lines.remove(atOffsets: offsets) }

    private func add(_ line: FoodCartLine) {
        lines.append(Line(item: .init(foodId: line.item.id, name: line.item.name, grams: line.grams,
                                      per100g: line.item.per100g.stored)))
    }

    private func save() {
        let existing: FoodSavedMeal? = if case .edit(let meal) = target { meal } else { nil }
        guard let meal = FoodLog.savedMeal(name: name, items: lines.map(\.item), id: existing?.id ?? UUID().uuidString,
                                           createdAt: existing?.createdAt) else { return }
        saving = true
        Task {
            let done = await model.saveMeal(meal, repo: repo)
            saving = false
            if done { dismiss() }
        }
    }

    private func delete(_ meal: FoodSavedMeal) {
        Task {
            await model.deleteMeal(meal, repo: repo)
            dismiss()
        }
    }
}
#endif
