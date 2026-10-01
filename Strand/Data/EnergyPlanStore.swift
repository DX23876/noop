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

    static let caloriesKey = "calories_in"
    static let proteinKey = "protein_g"
    static let carbsKey = "carbs_g"
    static let fatKey = "fat_g"
    /// Presence distinguishes an explicitly confirmed zero-intake day from an unknown day.
    static let loggedKey = "nutrition_logged"
    static let nutritionKeys = [caloriesKey, proteinKey, carbsKey, fatKey, loggedKey]

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

struct NutritionDay: Equatable, Sendable {
    enum Source: String, Sendable { case appleHealth, csv, manual }

    let day: String
    var calories: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var caloriesSource: Source?
    var macrosSource: Source?
    var healthSourceName: String?
    var isConfirmedNoIntake: Bool
}

struct ManualNutritionEntry: Equatable, Sendable {
    let day: String
    let calories: Double
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let isConfirmedNoIntake: Bool
}

// MARK: - Intake

extension Repository {

    /// Records one day's intake. One number per day, no food database — see the spec's exclusions.
    @discardableResult
    func recordIntake(kcal: Double, on day: String) async -> Bool {
        await recordManualNutrition(.init(day: day, calories: kcal, proteinG: nil, carbsG: nil,
                                          fatG: nil, isConfirmedNoIntake: false))
    }

    /// Replace one manual day's aggregate and read it back before claiming success.
    @discardableResult
    func recordManualNutrition(_ entry: ManualNutritionEntry) async -> Bool {
        guard let store = await storeHandle(), entry.calories.isFinite,
              entry.calories >= 0, entry.calories < 20_000,
              entry.isConfirmedNoIntake == (entry.calories == 0),
              !entry.isConfirmedNoIntake || [entry.proteinG, entry.carbsG, entry.fatG].allSatisfy({ $0 == nil }),
              [entry.proteinG, entry.carbsG, entry.fatG].allSatisfy({ value in
                  value.map { $0.isFinite && $0 >= 0 && $0 < 5_000 } ?? true
              }) else { return false }
        let optional = [(EnergyPlanStore.proteinKey, entry.proteinG),
                        (EnergyPlanStore.carbsKey, entry.carbsG),
                        (EnergyPlanStore.fatKey, entry.fatG)]
        var rows = [
            MetricPoint(day: entry.day, key: EnergyPlanStore.caloriesKey, value: entry.calories),
            MetricPoint(day: entry.day, key: EnergyPlanStore.loggedKey, value: 1),
        ]
        rows += optional.compactMap { key, value in
            value.map { MetricPoint(day: entry.day, key: key, value: $0) }
        }
        do {
            try await store.replaceMetricSeriesWindow(
                rows, deviceId: EnergyPlanStore.manualIntakeSource,
                keys: EnergyPlanStore.nutritionKeys, from: entry.day, to: entry.day)
            return await manualNutrition(on: entry.day) == entry
        } catch {
            return false
        }
    }

    func manualNutrition(on day: String) async -> ManualNutritionEntry? {
        guard let store = await storeHandle() else { return nil }
        func value(_ key: String) async -> Double? {
            (try? await store.metricSeries(deviceId: EnergyPlanStore.manualIntakeSource,
                                           key: key, from: day, to: day))?.first?.value
        }
        guard await value(EnergyPlanStore.loggedKey) != nil,
              let calories = await value(EnergyPlanStore.caloriesKey) else { return nil }
        return .init(day: day, calories: calories,
                     proteinG: await value(EnergyPlanStore.proteinKey),
                     carbsG: await value(EnergyPlanStore.carbsKey),
                     fatG: await value(EnergyPlanStore.fatKey),
                     isConfirmedNoIntake: calories == 0)
    }

    /// Removes a manually entered day. Only NOOP's own source is touched: an imported CSV day is not
    /// ours to delete from here.
    @discardableResult
    func deleteIntake(on day: String) async -> Bool {
        guard let store = await storeHandle() else { return false }
        do {
            try await store.replaceMetricSeriesWindow(
                [], deviceId: EnergyPlanStore.manualIntakeSource,
                keys: EnergyPlanStore.nutritionKeys, from: day, to: day)
            return await manualNutrition(on: day) == nil
        } catch {
            return false
        }
    }

    /// Intake per day from every source, in precedence order. Imported Health nutrition already
    /// resolves to one writer per day, and a later CSV or manual calorie replaces that field rather
    /// than being added to it.
    ///
    /// Apple Health is first because it is the intended path: NOOP ships no food diary, so a wearer who
    /// logs in a nutrition app and syncs it to Health should never have to retype anything. A CSV
    /// import overrides it, and a value typed here overrides both — later sources are more deliberate.
    func intakeByDay(from: String, to: String) async -> [String: Double] {
        await nutritionByDay(from: from, to: to).compactMapValues(\.calories)
    }

    /// Logged macronutrient grams per day, under the same "one source wins a day" rule as intake.
    ///
    /// Read for the thermic effect of food: protein costs roughly a quarter of its own energy to
    /// process, fat almost nothing, and a day's split is therefore worth more than a flat percentage
    /// of its calories. A day that logged calories but no macros simply has no entry here and falls
    /// back to the mixed-diet figure.
    func macrosByDay(from: String, to: String) async
        -> [String: (protein: Double?, carbs: Double?, fat: Double?)] {
        await nutritionByDay(from: from, to: to).mapValues {
            (protein: $0.proteinG, carbs: $0.carbsG, fat: $0.fatG)
        }
    }

    /// Resolve nutrition per field. A deliberate manual correction wins only the field it contains;
    /// its absent macros continue to use the imported values instead of being erased.
    func nutritionByDay(from: String, to: String) async -> [String: NutritionDay] {
        guard let store = await storeHandle() else { return [:] }
        let sources: [(id: String, source: NutritionDay.Source)] = [
            (Self.appleHealthSource, .appleHealth),
            (EnergyPlanStore.csvIntakeSource, .csv),
            (EnergyPlanStore.manualIntakeSource, .manual),
        ]
        var byDay: [String: NutritionDay] = [:]
        let sourceNames = NutritionSourcePreferences.healthSourceByDay
        for candidate in sources {
            let markerDays = Set(((try? await store.metricSeries(
                deviceId: candidate.id, key: EnergyPlanStore.loggedKey, from: from, to: to)) ?? []).map(\.day))
            for key in [EnergyPlanStore.caloriesKey, EnergyPlanStore.proteinKey,
                        EnergyPlanStore.carbsKey, EnergyPlanStore.fatKey] {
                let rows = (try? await store.metricSeries(deviceId: candidate.id, key: key,
                                                          from: from, to: to)) ?? []
                for row in rows where row.value > 0 || (candidate.source == .manual && markerDays.contains(row.day)) {
                    var entry = byDay[row.day] ?? NutritionDay(
                        day: row.day, calories: nil, proteinG: nil, carbsG: nil, fatG: nil,
                        caloriesSource: nil, macrosSource: nil,
                        healthSourceName: sourceNames[row.day], isConfirmedNoIntake: false)
                    switch key {
                    case EnergyPlanStore.caloriesKey:
                        entry.calories = row.value
                        entry.caloriesSource = candidate.source
                        entry.isConfirmedNoIntake = candidate.source == .manual && row.value == 0
                    case EnergyPlanStore.proteinKey: entry.proteinG = row.value; entry.macrosSource = candidate.source
                    case EnergyPlanStore.carbsKey: entry.carbsG = row.value; entry.macrosSource = candidate.source
                    default: entry.fatG = row.value; entry.macrosSource = candidate.source
                    }
                    byDay[row.day] = entry
                }
            }
        }
        return byDay
    }
}
