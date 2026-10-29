import Foundation
import StrandCore
import StrandAnalytics
import WhoopStore

// EnergyPlanStore.swift — the small amount of state the two energy pages own.
//
// The planner owns no calorie model (see `EnergyPlanning`), so what is stored here is only what the
// wearer told us: which basal formula applies from when, how active they say they are, what they are
// aiming for, and what they ate. Everything else is read from the engines that already exist.
//
// THE FORMULA LOG IS DATA, NOT A SETTING. It is append-only and dated, so "which formula applied on
// day X" is answered from what was recorded rather than from whatever the switch currently says. That
// is what keeps a switch made today from rewriting what yesterday showed.

/// Intake, the basal-formula log and the planning inputs.
enum EnergyPlanStore {

    // MARK: - Keys

    static let formulaLogKey = "energy.bmrFormulaLog"
    static let activityLevelKey = "energy.activityLevel"
    static let goalKey = "energy.goal"
    static let targetRateKey = "energy.targetKgPerWeek"

    /// Manually entered intake is written under its OWN source id, never under `nutrition-csv`.
    /// Labelling a typed number as a CSV import would be a lie about provenance, and provenance is
    /// what the balance tier is judged on.
    static let manualIntakeSource = NutritionReads.manualIntakeSource

    /// Where `NutritionCsvImport` puts an imported day. Read alongside the manual source.
    static let csvIntakeSource = NutritionReads.csvIntakeSource

    static let caloriesKey = NutritionReads.caloriesKey
    static let proteinKey = NutritionReads.proteinKey
    static let carbsKey = NutritionReads.carbsKey
    static let fatKey = NutritionReads.fatKey
    /// Presence distinguishes an explicitly confirmed zero-intake day from an unknown day.
    static let loggedKey = NutritionReads.loggedKey
    static let nutritionKeys = NutritionReads.keys

    // MARK: - The formula log

    /// The stored log, seeded when absent or unreadable.
    static var formulaLog: BmrFormulaLog {
        BmrFormulaLog.decode(UserDefaults.standard.string(forKey: formulaLogKey) ?? "")
    }

    /// Appends a switch effective from `day`. Append-only: this can only ever add an entry.
    static func switchFormula(to formula: BasalFormula, effectiveFrom day: String) {
        let next = formulaLog.appending(formula, effectiveFrom: day)
        UserDefaults.standard.set(next.encodedJSON(), forKey: formulaLogKey)
    }

    // MARK: - Planning inputs

    static var activityLevel: ActivityLevel {
        get {
            ActivityLevel(rawValue: UserDefaults.standard.string(forKey: activityLevelKey) ?? "")
                ?? .light
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: activityLevelKey) }
    }

    /// Target rate of weight change in kg per week. Negative loses, positive gains, zero holds.
    static var targetKgPerWeek: Double {
        get { UserDefaults.standard.double(forKey: targetRateKey) }
        set { UserDefaults.standard.set(newValue, forKey: targetRateKey) }
    }
}

// MARK: - Intake

extension Repository {

    /// Records one day's intake. One number per day, no food database — see the spec's exclusions.
    @discardableResult
    func recordIntake(kcal: Double, on day: String) async -> Bool {
        await recordManualNutrition(.init(day: day, calories: kcal, proteinG: nil, carbsG: nil,
                                          fatG: nil, isConfirmedNoIntake: false))
    }

    /// Replace one manual day's aggregate and read it back before claiming success (`NutritionReads`).
    @discardableResult
    func recordManualNutrition(_ entry: ManualNutritionEntry) async -> Bool {
        guard let store = await storeHandle() else { return false }
        return await NutritionReads.recordManualNutrition(store: store, entry)
    }

    func manualNutrition(on day: String) async -> ManualNutritionEntry? {
        guard let store = await storeHandle() else { return nil }
        return await NutritionReads.manualNutrition(store: store, on: day)
    }

    /// Removes a manually entered day. Only NOOP's own source is touched: an imported CSV day is not
    /// ours to delete from here.
    @discardableResult
    func deleteIntake(on day: String) async -> Bool {
        guard let store = await storeHandle() else { return false }
        return await NutritionReads.deleteIntake(store: store, on: day)
    }

    /// Intake per day from every source, in precedence order (`NutritionReads.nutritionByDay`).
    func intakeByDay(from: String, to: String) async -> [String: Double] {
        await nutritionByDay(from: from, to: to).compactMapValues(\.calories)
    }

    /// Logged macronutrient grams per day, under the same "one source wins a day" rule as intake.
    func macrosByDay(from: String, to: String) async
        -> [String: (protein: Double?, carbs: Double?, fat: Double?)] {
        await nutritionByDay(from: from, to: to).mapValues {
            (protein: $0.proteinG, carbs: $0.carbsG, fat: $0.fatG)
        }
    }

    /// Resolve nutrition per field, shared with the Android core (`NutritionReads`).
    func nutritionByDay(from: String, to: String) async -> [String: NutritionDay] {
        guard let store = await storeHandle() else { return [:] }
        return await NutritionReads.nutritionByDay(store: store, from: from, to: to,
                                                   healthSourceNames: NutritionSourcePreferences.healthSourceByDay)
    }
}
