#if os(iOS)
import SwiftUI
import StrandCore
import StrandImport

/// A label's values in a form: filled from a photo read on the phone, every field editable, saved as the wearer's
/// own food with the barcode when there is one.
struct FoodLabelForm: View {
    let barcode: String?
    let saved: (FoodItem) -> Void

    @EnvironmentObject private var repo: Repository
    @State private var name = ""
    @State private var brand = ""
    @State private var serving: Double?
    @State private var values: [FoodNutrient: Double] = [:]
    @State private var showCamera = false
    @State private var reading = false
    @State private var readFailed = false

    private static let fields: [FoodNutrient] = [.energyKcal, .fatG, .satFatG, .carbsG, .sugarG, .fiberG, .proteinG, .saltG]

    var body: some View {
        Form {
            Section {
                Button(action: openCamera) {
                    if reading { ProgressView() } else { Label("Photograph the nutrition label", systemImage: "camera") }
                }
                .disabled(reading)
            } footer: {
                Text(readFailed ? String(localized: "The label could not be read. Type the values instead.")
                                : String(localized: "The photo is read on this iPhone. Check every value before saving."))
            }
            Section {
                TextField("Name", text: $name)
                TextField("Brand", text: $brand)
                if let barcode { LabeledContent("Barcode", value: barcode) }
            }
            Section("Per 100 g") {
                ForEach(Self.fields, id: \.self) { nutrient in
                    FoodValueField(title: FoodText.nutrient(nutrient), unit: nutrient.unit, value: valueBinding(nutrient))
                }
                FoodValueField(title: String(localized: "Portion"), unit: .g, value: $serving)
            }
            Section {
                Button("Save food", action: save).disabled(!complete)
            }
        }
        .sheet(isPresented: $showCamera) { FoodCamera(onImage: read).ignoresSafeArea() }
    }

    private var complete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && FoodNutrient.macros.allSatisfy { values[$0] != nil }
    }

    /// The form's field for one nutrient, over the one dictionary that holds them all.
    private func valueBinding(_ nutrient: FoodNutrient) -> Binding<Double?> {
        Binding(get: { values[nutrient] }, set: { values[nutrient] = $0 })
    }

    private func openCamera() { showCamera = true }

    private func read(_ image: UIImage) {
        showCamera = false
        guard let jpeg = FoodPhoto.jpeg(image, longestSide: 2_400, quality: 0.9) else { return }
        reading = true
        Task {
            let reading = await FoodLabelReader.shared.read(jpeg)
            self.reading = false
            readFailed = reading?.per100.isEmpty ?? true
            for (key, value) in reading?.per100 ?? [:] { if let n = FoodNutrient(rawValue: key) { values[n] = value } }
            if let amount = reading?.servingAmount { serving = amount }
        }
    }

    private func save() {
        Task {
            guard let store = await repo.storeHandle() else { return }
            var amounts = NutrientAmounts(values)
            if amounts[.sodiumMg] == nil, let salt = amounts[.saltG] { amounts[.sodiumMg] = salt / 2.5 * 1_000 }
            let item = FoodItem(id: "own:new", source: .online, name: name.trimmingCharacters(in: .whitespaces),
                                brand: brand.isEmpty ? nil : brand, servingG: serving, per100g: amounts, barcode: barcode)
            if let kept = await FoodLibrary.saveOwn(store: store, item, origin: .label) { saved(kept) }
        }
    }
}
#endif
