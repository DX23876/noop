import Foundation
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
    static let manualIntakeSource = "manual-intake"

    /// Where `NutritionCsvImport` puts an imported day. Read alongside the manual source.
    static let csvIntakeSource = "nutrition-csv"

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
        guard let store = await storeHandle(), kcal > 0, kcal < 20_000, kcal.isFinite else {
            return false
        }
        let row = MetricPoint(day: day, key: "calories_in", value: kcal)
        return (try? await store.upsertMetricSeries([row],
                                                    deviceId: EnergyPlanStore.manualIntakeSource)) != nil
    }

    /// Removes a manually entered day. Only NOOP's own source is touched: an imported CSV day is not
    /// ours to delete from here.
    @discardableResult
    func deleteIntake(on day: String) async -> Bool {
        guard let store = await storeHandle() else { return false }
        return (try? await store.deleteMetricSeriesPoint(deviceId: EnergyPlanStore.manualIntakeSource,
                                                         day: day, key: "calories_in")) != nil
    }

    /// Intake per day from every source, in precedence order — the later source wins a day it shares
    /// with an earlier one.
    ///
    /// The same "one source wins a day, never a sum" rule weight already follows. Summing them would
    /// double a day that arrived through Health AND was typed here.
    ///
    /// Apple Health is first because it is the intended path: NOOP ships no food diary, so a wearer who
    /// logs in a nutrition app and syncs it to Health should never have to retype anything. A CSV
    /// import overrides it, and a value typed here overrides both — later sources are more deliberate.
    func intakeByDay(from: String, to: String) async -> [String: Double] {
        guard let store = await storeHandle() else { return [:] }
        var byDay: [String: Double] = [:]
        for source in [Self.appleHealthSource, EnergyPlanStore.csvIntakeSource,
                       EnergyPlanStore.manualIntakeSource] {
            let rows = (try? await store.metricSeries(deviceId: source, key: "calories_in",
                                                      from: from, to: to)) ?? []
            for row in rows where row.value > 0 { byDay[row.day] = row.value }
        }
        return byDay
    }

    /// Logged macronutrient grams per day, under the same "one source wins a day" rule as intake.
    ///
    /// Read for the thermic effect of food: protein costs roughly a quarter of its own energy to
    /// process, fat almost nothing, and a day's split is therefore worth more than a flat percentage
    /// of its calories. A day that logged calories but no macros simply has no entry here and falls
    /// back to the mixed-diet figure.
    func macrosByDay(from: String, to: String) async
        -> [String: (protein: Double?, carbs: Double?, fat: Double?)] {
        guard let store = await storeHandle() else { return [:] }
        var byDay: [String: (protein: Double?, carbs: Double?, fat: Double?)] = [:]
        for source in [Self.appleHealthSource, EnergyPlanStore.csvIntakeSource,
                       EnergyPlanStore.manualIntakeSource] {
            for (key, path) in [("protein_g", 0), ("carbs_g", 1), ("fat_g", 2)] {
                let rows = (try? await store.metricSeries(deviceId: source, key: key,
                                                          from: from, to: to)) ?? []
                for row in rows where row.value > 0 {
                    var entry = byDay[row.day] ?? (nil, nil, nil)
                    switch path {
                    case 0: entry.protein = row.value
                    case 1: entry.carbs = row.value
                    default: entry.fat = row.value
                    }
                    byDay[row.day] = entry
                }
            }
        }
        return byDay
    }
}
