#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// Correcting a product's values. Open Food Facts rows are filled in by volunteers and some of them are wrong, so
/// every scanned or searched product can be put right here. The correction is saved as the wearer's own food,
/// which from then on stands in for that row everywhere it appears (`FoodLibrary.preferKept`), and never leaves
/// the phone. Energy is resolved once through `FoodEnergy`, so the figure, the split and the note on this screen
/// cannot disagree about the same product.
struct FoodProductEditSheet: View {
    let item: FoodItem
    let model: ForgeFoodModel
    /// The corrected product, as stored.
    let saved: (FoodItem) -> Void

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var brand: String
    @State private var serving: Double?
    @State private var values: [FoodNutrient: Double]
    @State private var recent: [FoodLogEntry] = []
    @State private var restateEntries = true
    @State private var saving = false

    /// The label's fields, in the order they are printed on a pack.
    private static let fields: [FoodNutrient] = [.fatG, .satFatG, .carbsG, .sugarG, .fiberG, .proteinG, .saltG]

    init(item: FoodItem, model: ForgeFoodModel, saved: @escaping (FoodItem) -> Void) {
        self.item = item
        self.model = model
        self.saved = saved
        _name = State(initialValue: item.name)
        _brand = State(initialValue: item.brand ?? "")
        _serving = State(initialValue: item.servingG)
        _values = State(initialValue: item.per100g.values)
    }

    private var amounts: NutrientAmounts { NutrientAmounts(values) }
    private var check: FoodEnergy.Check? { FoodEnergy.check(amounts) }
    private var complete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && FoodEnergy.required.allSatisfy { values[$0] != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    energyCard
                    section(String(localized: "Per 100 g"))
                    nutrientGroup
                    section(String(localized: "Product"))
                    productGroup
                    if !recent.isEmpty {
                        section(String(localized: "Already logged"))
                        restateGroup
                    }
                    notes
                    saveButton
                }
                .padding(20)
                .padding(.bottom, 8)
            }
            .background(ForgeColor.canvas.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Check values")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
            .task { recent = await model.correctableEntries(for: item, repo: repo) }
        }
        .tint(ForgeColor.accent)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(ForgeFont.section).foregroundStyle(ForgeColor.text).padding(.top, 4)
    }

    // MARK: Energy

    /// The product's energy: the figure, what the nutrients beside it come to, and the one note that says how the
    /// two stand to each other.
    private var energyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Energy").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                Spacer(minLength: 8)
                ForgeBadge(text: badge.text, tone: badge.tone)
            }
            // The figure here is what the NUTRIENTS come to, never a second copy of the stated value: that one is
            // the field below, and showing one number twice is how two readouts of a fact start to disagree.
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(FoodText.kcal(check?.computed)).font(ForgeFont.rounded(40, .bold)).foregroundStyle(ForgeColor.text)
                    .contentTransition(.numericText())
                Text("kcal from the nutrients").font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
            }
            .animation(.smooth, value: check?.computed)
            if let check {
                FoodEnergySplitBar(parts: FoodEnergySplitBar.parts(of: amounts), total: check.computed)
                Text(energyNote).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                if check.isMissing || check.disagrees {
                    Button(action: takeComputed) {
                        Text("Use \(FoodText.kcal(check.computed)) kcal")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(ForgeColor.accent)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .background(Capsule().fill(ForgeColor.accent.opacity(ForgeOpacity.wash)))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Protein, carbohydrate and fat are what energy is worked out from. Fill those three in and the figure follows.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
        }
        .forgeCard()
    }

    private var badge: (text: String, tone: ForgeBadge.Tone) {
        guard let check else { return (String(localized: "incomplete"), .neutral) }
        if check.isMissing { return (String(localized: "worked out"), .neutral) }
        return check.disagrees ? (String(localized: "does not fit"), .attention) : (String(localized: "fits"), .good)
    }

    /// One sentence about the energy figure, from the one check the card draws from.
    private var energyNote: String {
        guard let check else { return "" }
        if check.isMissing {
            return String(localized: "This product states no energy. The figure comes from its protein, carbohydrate and fat, with the factors a label is calculated from.")
        }
        guard check.disagrees, let difference = check.difference else {
            return String(localized: "The stated figure fits the nutrients below it.")
        }
        let computed = String(localized: "The nutrients below come to \(FoodText.kcal(check.computed)) kcal.")
        let tail = difference > 0
            ? String(localized: "The stated figure is higher. One of the two is wrong, or the product is sweetened with sugar alcohols, which carry less energy than the carbohydrate they are counted in.")
            : String(localized: "The stated figure is lower. Check both before you keep them.")
        return computed + " " + tail
    }

    private func takeComputed() {
        guard let computed = check?.computed else { return }
        values[.energyKcal] = (computed * 10).rounded() / 10
    }

    // MARK: Fields

    private var nutrientGroup: some View {
        ForgeGroup {
            FoodEditField(nutrient: .energyKcal, value: field(.energyKcal))
            ForEach(Self.fields, id: \.self) { nutrient in
                ForgeRowDivider()
                FoodEditField(nutrient: nutrient, value: field(nutrient))
            }
        }
    }

    private var productGroup: some View {
        ForgeGroup {
            labelled(String(localized: "Name")) { TextField("Name", text: $name).multilineTextAlignment(.trailing) }
            ForgeRowDivider()
            labelled(String(localized: "Brand")) { TextField("Brand", text: $brand).multilineTextAlignment(.trailing) }
            ForgeRowDivider()
            labelled(String(localized: "Portion")) {
                HStack(spacing: 4) {
                    TextField("–", value: $serving, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("g").foregroundStyle(ForgeColor.secondary)
                }
            }
            if let barcode = item.barcode {
                ForgeRowDivider()
                labelled(String(localized: "Barcode")) {
                    Text(barcode).font(ForgeFont.figure(15)).foregroundStyle(ForgeColor.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(.callout)).foregroundStyle(ForgeColor.text)
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// The field for one nutrient, over the one dictionary that holds them all, so an emptied field means unknown.
    private func field(_ nutrient: FoodNutrient) -> Binding<Double?> {
        Binding(get: { values[nutrient] }, set: { values[nutrient] = $0 })
    }

    // MARK: Entries already logged

    private var restateGroup: some View {
        ForgeGroup {
            Toggle(isOn: $restateEntries) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Correct what is logged").font(.system(.callout, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    Text("\(recent.count) entries from the last 14 days follow the corrected values. Their amounts and times stay.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            .padding(16)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your correction stays on this iPhone. It is kept as your own food and stands in for this product wherever it appears.")
            Text(FoodText.sourceNote(item))
        }
        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
    }

    private var saveButton: some View {
        Button(action: save) {
            Text(saving ? String(localized: "Saving") : String(localized: "Save values"))
                .font(.system(.headline))
                .foregroundStyle(ForgeColor.onAccent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(complete ? ForgeColor.accent : ForgeColor.fill))
        }
        .buttonStyle(.plain)
        .disabled(!complete || saving)
    }

    private func cancel() { dismiss() }

    private func save() {
        saving = true
        Task {
            var next = item
            next.name = name.trimmingCharacters(in: .whitespaces)
            next.brand = brand.trimmingCharacters(in: .whitespaces).isEmpty ? nil : brand.trimmingCharacters(in: .whitespaces)
            next.servingG = serving
            next.per100g = amounts
            // Sodium follows salt where the label only prints one of them, the same way a typed label does.
            if next.per100g[.sodiumMg] == nil, let salt = next.per100g[.saltG] { next.per100g[.sodiumMg] = salt / 2.5 * 1_000 }
            let corrected = await model.correct(next, restating: restateEntries ? recent : [], repo: repo)
            saving = false
            if let corrected { saved(corrected) }
            dismiss()
        }
    }
}

/// Where a product's energy comes from: one bar, a segment per nutrient that carries energy, in the nutrient's
/// own colour. Drawn from `FoodEnergy.contributions`, so it cannot say a different thing than the figure above it.
struct FoodEnergySplitBar: View {
    struct Part: Identifiable {
        let nutrient: FoodNutrient
        let kcal: Double
        var id: FoodNutrient { nutrient }
    }

    let parts: [Part]
    let total: Double

    /// The split of one set of amounts, from the core's arithmetic.
    static func parts(of amounts: NutrientAmounts) -> [Part] {
        FoodEnergy.contributions(amounts).map { Part(nutrient: $0.nutrient, kcal: $0.kcal) }
    }

    private static let gap = 2.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let gaps = Double(max(0, parts.count - 1)) * Self.gap
                let available = max(0, geometry.size.width - gaps)
                HStack(spacing: Self.gap) {
                    if parts.isEmpty {
                        Capsule().fill(ForgeColor.fill)
                    } else {
                        ForEach(parts) { part in
                            Capsule().fill(FoodNutrientBadge.tint(part.nutrient))
                                .frame(width: max(2, available * share(part.kcal)))
                        }
                    }
                }
            }
            .frame(height: 10)
            FlowRows(spacing: 8) {
                ForEach(parts) { part in
                    HStack(spacing: 6) {
                        Circle().fill(FoodNutrientBadge.tint(part.nutrient)).frame(width: 8, height: 8)
                        Text("\(FoodText.nutrient(part.nutrient)) \(FoodText.kcal(part.kcal)) kcal")
                            .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private func share(_ kcal: Double) -> Double {
        guard total > 0 else { return 0 }
        return kcal / total
    }

    private var accessibilityText: String {
        parts.map { "\(FoodText.nutrient($0.nutrient)) \(FoodText.kcal($0.kcal)) kcal" }.joined(separator: ", ")
    }
}

/// One nutrient's value on the correction screen: its mark, its name and the figure, empty meaning unknown.
struct FoodEditField: View {
    let nutrient: FoodNutrient
    @Binding var value: Double?

    var body: some View {
        HStack(spacing: 12) {
            FoodNutrientBadge(nutrient: nutrient)
            Text(FoodText.nutrient(nutrient)).font(.system(.callout)).foregroundStyle(ForgeColor.text).lineLimit(1)
            Spacer(minLength: 8)
            TextField("–", value: $value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(ForgeFont.figure(17))
                .frame(minWidth: 64, maxWidth: 110)
            Text(unitText).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).frame(width: 30, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var unitText: String {
        switch nutrient.unit { case .kcal: "kcal"; case .g: "g"; case .mg: "mg"; case .ug: "µg" }
    }
}
#endif
