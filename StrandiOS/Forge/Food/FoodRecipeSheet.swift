#if os(iOS)
import SwiftUI

/// Save a meal's foods as a recipe: a name and how many servings they make.
struct FoodRecipeSheet: View {
    let batch: FoodEntryBatch
    let model: ForgeFoodModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var servings = 1

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Stepper("Servings: \(servings)", value: $servings, in: 1...20)
                Section("Foods") {
                    ForEach(batch.entries.filter { $0.grams != nil }) { entry in
                        LabeledContent(entry.name, value: "\(FoodText.grams(entry.grams)) g")
                    }
                }
            }
            .navigationTitle("Save as recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func cancel() { dismiss() }
    private func save() {
        Task { _ = await model.makeRecipe(name: name, from: batch.entries, servings: Double(servings), repo: repo); dismiss() }
    }
}
#endif
