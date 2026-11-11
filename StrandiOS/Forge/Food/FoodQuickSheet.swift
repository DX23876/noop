#if os(iOS)
import SwiftUI

/// Calories without a food: a canteen plate, a restaurant meal.
struct FoodQuickSheet: View {
    let save: (FoodQuickEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kcal: Double?
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?
    @State private var time: Date

    init(at: Date, save: @escaping (FoodQuickEntry) -> Void) {
        self.save = save
        _time = State(initialValue: at)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("What was it?", text: $name)
                Section("Energy") {
                    TextField("kcal", value: $kcal, format: .number).keyboardType(.numberPad)
                }
                Section("If you know them") {
                    TextField("Protein (g)", value: $protein, format: .number).keyboardType(.decimalPad)
                    TextField("Carbs (g)", value: $carbs, format: .number).keyboardType(.decimalPad)
                    TextField("Fat (g)", value: $fat, format: .number).keyboardType(.decimalPad)
                }
                DatePicker("Time", selection: $time)
            }
            .navigationTitle("Calories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: confirm).disabled(!valid) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var valid: Bool { (kcal ?? -1) >= 0 && (kcal ?? 0) < 20_000 }
    private func cancel() { dismiss() }
    private func confirm() {
        save(FoodQuickEntry(name: name.isEmpty ? String(localized: "Quick entry") : name, kcal: kcal ?? 0,
                            protein: protein, carbs: carbs, fat: fat, at: time))
        dismiss()
    }
}
#endif
