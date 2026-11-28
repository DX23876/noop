import SwiftUI
import StrandCore
import StrandAnalytics
import StrandDesign

// MARK: - Switching the basal formula, with what it rests on stated
//
// A formula change moves the basal rate by roughly 50 to 200 kcal a day. An unexplained step that size
// in an energy curve reads as a bug — and the wearer is right to read it that way. So the switch is
// confirmed rather than toggled, the sheet states the size of the step before it happens, and it names
// what the new formula depends on.
//
// The honesty that matters most here: Katch-McArdle is only better when the body-fat number is good.
// On a tape estimate carrying ±4 percentage points its error can be comparable to the formula it
// replaces. Offering it silently as an upgrade would be the wrong claim.

struct FormulaSwitchSheet: View {
    @ObservedObject var model: EnergyPlanModel
    let target: BasalFormula
    let profile: UserProfile
    let onSwitched: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var measuredText = ""
    @State private var measuredDay = Date()
    @State private var confirmFar = false

    private var measured: MeasuredRestingRate? {
        let value = Double(measuredText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        return value.flatMap { model.measuredRate(kcalPerDay: $0, on: Repository.localDayKey(measuredDay), profile: profile) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    if target.needsMeasurement { measuredEntry }
                    if !target.needsMeasurement, let delta = model.switchDelta(to: target, profile: profile) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(delta >= 0
                                 ? String(localized: "Your basal rate rises by \(Int(delta.rounded())) kcal a day")
                                 : String(localized: "Your basal rate falls by \(Int(abs(delta).rounded())) kcal a day"))
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Applied to your whole history, past days included, so every day is compared on the same formula.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if target.needsBodyFat {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What this rests on")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(restsOnText)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if target.needsBodyFat {
                        Text("Katch–McArdle uses the body-fat reading in force on each day. Days before your first reading use Mifflin–St Jeor, so the curve steps where your first reading begins.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(NoopMetrics.gap)
            }
            .navigationTitle("Change formula")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Change") {
                        if target.needsMeasurement, let measured, !measured.isPlausible {
                            confirmFar = true
                        } else {
                            apply()
                        }
                    }
                    .disabled(target.needsMeasurement && measured == nil)
                }
            }
            .alert("Is this value right?", isPresented: $confirmFar) {
                Button("Use it") { apply() }
                Button("Check again", role: .cancel) {}
            } message: {
                Text("It is more than 40 % away from what the formula expects for your body. A typing mistake is likely, but a measurement can be this far off.")
            }
        }
        .onAppear {
            if let stored = EnergyPlanStore.measuredRate {
                measuredText = String(Int(stored.kcalPerDay.rounded()))
                measuredDay = WeightSeries.date(forDay: stored.day) ?? Date()
            }
        }
    }

    private func apply() {
        if target.needsMeasurement {
            guard let measured else { return }
            EnergyPlanStore.measuredRate = measured
        }
        if target != model.currentFormula {
            EnergyPlanStore.switchFormula(to: target, effectiveFrom: model.today)
        }
        Task { await onSwitched(); dismiss() }
    }

    /// The measured value and its day. Kept as its ratio to Mifflin–St Jeor for the body that day, so it
    /// follows the weight afterwards, and applied to the whole history like every formula choice.
    @ViewBuilder private var measuredEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your measured resting rate")
                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            HStack {
                Text("kcal a day").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                TextField("kcal", text: $measuredText)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
            }
            DatePicker("Measured on", selection: $measuredDay, in: ...Date(), displayedComponents: .date)
            Text("A measurement at rest, for example by a sports doctor or a nutrition clinic. Equations can miss a single body by several hundred kcal, a measurement does not. NOOP keeps how far it is from Mifflin–St Jeor and lets that follow your weight. It applies to your whole history, like every formula choice.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Names the source of the body-fat figure, because Katch-McArdle is only as good as it is.
    private var restsOnText: String {
        guard let reading = model.bodyFatToday else {
            return String(localized: "This formula needs a body-fat reading, and there is none yet.")
        }
        switch reading.source {
        case "dexa":
            return String(localized: "A DEXA reading of \(reading.value.formatted(.number.precision(.fractionLength(1)))) %. That is the strongest input this formula can have.")
        case "caliper", "bia", "inbody":
            return String(localized: "A measured reading of \(reading.value.formatted(.number.precision(.fractionLength(1)))) %. Good enough to work from, though less certain than a scan.")
        case "navy":
            return String(localized: "A tape estimate of \(reading.value.formatted(.number.precision(.fractionLength(1)))) %, which carries about ±4 percentage points. On a number that uncertain, this formula is not reliably better than the one it replaces — it is a different kind of wrong, not a smaller one.")
        default:
            return String(localized: "A reading of \(reading.value.formatted(.number.precision(.fractionLength(1)))) %. How much this formula improves on the last one depends entirely on how that figure was obtained.")
        }
    }
}

// MARK: - One number for one day
//
// No food database, and deliberately so: that is a separate app and would need a server this project
// does not have. The balance tier needs one figure per day and nothing more — and for a strap-only
// setup it is the only remaining way to check the level at all.

struct IntakeEntrySheet: View {
    let onSave: (ManualNutritionEntry) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    @State private var text = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var saving = false
    @State private var error: String?

    private func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: $day, in: ...Date(),
                               displayedComponents: .date)
                    HStack {
                        Text("Calories in")
                        Spacer()
                        TextField("kcal", text: $text)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                    }
                    DisclosureGroup("Macronutrients (optional)") {
                        nutrientRow("Protein", text: $protein)
                        nutrientRow("Carbohydrates", text: $carbs)
                        nutrientRow("Fat", text: $fat)
                    }
                    Button("No intake this day") { save(calories: 0, confirmedZero: true) }
                        .disabled(saving)
                } footer: {
                    Text("A fallback for a day Apple Health did not receive. NOOP ships no food database and is not trying to be a diary — anything you log in a nutrition app that syncs to Health already counts here without being retyped.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .forgeListBackground()
            .navigationTitle("Intake")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let kcal = number(text), kcal > 0 else { return }
                        save(calories: kcal, confirmedZero: false)
                    }
                    .disabled((number(text) ?? 0) <= 0 || saving)
                }
            }
        }
    }

    private func nutrientRow(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("g", text: text)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
            #if os(iOS)
                .keyboardType(.decimalPad)
            #endif
        }
    }

    private func save(calories: Double, confirmedZero: Bool) {
        let values = [number(protein), number(carbs), number(fat)]
        guard values.allSatisfy({ $0.map { $0 >= 0 } ?? true }) else {
            error = String(localized: "Macronutrients cannot be negative.")
            return
        }
        saving = true
        error = nil
        let entry = ManualNutritionEntry(
            day: Repository.localDayKey(day), calories: calories,
            proteinG: confirmedZero ? nil : values[0],
            carbsG: confirmedZero ? nil : values[1],
            fatG: confirmedZero ? nil : values[2],
            isConfirmedNoIntake: confirmedZero)
        Task {
            if await onSave(entry) {
                dismiss()
            } else {
                saving = false
                error = String(localized: "Could not save the entry. Your input is still here — try again.")
            }
        }
    }
}
