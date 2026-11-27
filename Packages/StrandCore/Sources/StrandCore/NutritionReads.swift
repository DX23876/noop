import Foundation
import StrandAnalytics
import WhoopStore

/// One day's resolved nutrition: each field from the most deliberate source that logged it.
public struct NutritionDay: Equatable, Sendable {
    public enum Source: String, Sendable { case appleHealth, healthConnect, csv, foodLog, manual }

    public let day: String
    public var calories: Double?
    public var proteinG: Double?
    public var carbsG: Double?
    public var fatG: Double?
    public var caloriesSource: Source?
    public var macrosSource: Source?
    public var healthSourceName: String?
    public var isConfirmedNoIntake: Bool

    public init(day: String, calories: Double?, proteinG: Double?, carbsG: Double?, fatG: Double?,
                caloriesSource: Source?, macrosSource: Source?, healthSourceName: String?, isConfirmedNoIntake: Bool) {
        self.day = day; self.calories = calories; self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        self.caloriesSource = caloriesSource; self.macrosSource = macrosSource
        self.healthSourceName = healthSourceName; self.isConfirmedNoIntake = isConfirmedNoIntake
    }
}

/// What the wearer typed in for one day.
public struct ManualNutritionEntry: Equatable, Sendable {
    public let day: String
    public let calories: Double
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?
    public let isConfirmedNoIntake: Bool

    public init(day: String, calories: Double, proteinG: Double?, carbsG: Double?, fatG: Double?, isConfirmedNoIntake: Bool) {
        self.day = day; self.calories = calories; self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        self.isConfirmedNoIntake = isConfirmedNoIntake
    }
}

/// The intake lanes the energy plan and its balance estimate read, shared by the Apple app and the Android core
/// (parity plan 2.3). Apple Health first, a CSV import over it, the food log over both, a typed day value over
/// all of them, field by field. The food log comes after the imports because a day logged here is a day the
/// wearer logged on purpose, and NOOP never sums two sources for the same day (decision 2026-09-30).
public enum NutritionReads {
    public static let manualIntakeSource = "manual-intake"
    public static let csvIntakeSource = "nutrition-csv"
    public static let caloriesKey = "calories_in"
    public static let proteinKey = "protein_g"
    public static let carbsKey = "carbs_g"
    public static let fatKey = "fat_g"
    /// Marks a manual day as logged, so a typed zero ("ate nothing") is told apart from no entry.
    public static let loggedKey = "nutrition_logged"
    public static let keys = [caloriesKey, proteinKey, carbsKey, fatKey, loggedKey]

    /// What digesting each day the wearer marked as completely logged cost (`Digestion.kcal`), from that day's
    /// energy and macronutrients. A day not marked is left out: half a log would price half the food.
    public static func digestionByDay(store: WhoopStore, from: String, to: String) async -> [String: Double] {
        let complete = (try? await store.foodCompleteDays(from: from, to: to)) ?? []
        guard !complete.isEmpty else { return [:] }
        let days = await nutritionByDay(store: store, from: from, to: to)
        var out: [String: Double] = [:]
        for day in complete {
            let n = days[day]
            out[day] = Digestion.kcal(caloriesKcal: n?.calories, proteinG: n?.proteinG, carbsG: n?.carbsG,
                                      fatG: n?.fatG) ?? 0
        }
        return out
    }

    /// Resolve nutrition per field. A deliberate manual correction wins only the field it contains; its absent
    /// macros continue to use the imported values instead of being erased.
    /// `fields` limits the read to the keys the caller needs, which is all a single-measure read wants:
    /// the precedence is decided field by field anyway, so asking for one gives the same answer for that
    /// one. The catalogue sweep reads the four nutrition measures separately, and reading all four fields
    /// each time made it twenty-five queries per measure instead of six.
    public static func nutritionByDay(store: WhoopStore, from: String, to: String,
                                      healthSourceNames: [String: String] = [:],
                                      fields: Set<String>? = nil) async -> [String: NutritionDay] {
        let sources: [(id: String, source: NutritionDay.Source)] = [
            (MetricResolver.appleHealthSource, .appleHealth), (MetricResolver.healthConnectSource, .healthConnect),
            (csvIntakeSource, .csv),
            (WhoopStore.foodLogSourceId, .foodLog), (manualIntakeSource, .manual),
        ]
        let wanted = [caloriesKey, proteinKey, carbsKey, fatKey].filter { fields?.contains($0) ?? true }
        var byDay: [String: NutritionDay] = [:]
        for candidate in sources {
            // Only the typed lane is gated on the marker, so only the typed lane has to read it.
            let markerDays = candidate.source != .manual ? Set<String>()
                : Set(((try? await store.metricSeries(
                    deviceId: candidate.id, key: loggedKey, from: from, to: to)) ?? []).map(\.day))
            for key in wanted {
                let rows = (try? await store.metricSeries(deviceId: candidate.id, key: key, from: from, to: to)) ?? []
                // The food log banks a day only when it has entries, so its zero is a logged zero (water, black
                // coffee), not a gap; the other sources write zero for days nobody logged.
                for row in rows where row.value > 0 || candidate.source == .foodLog
                    || (candidate.source == .manual && markerDays.contains(row.day)) {
                    var entry = byDay[row.day] ?? NutritionDay(
                        day: row.day, calories: nil, proteinG: nil, carbsG: nil, fatG: nil,
                        caloriesSource: nil, macrosSource: nil,
                        healthSourceName: healthSourceNames[row.day], isConfirmedNoIntake: false)
                    switch key {
                    case caloriesKey:
                        entry.calories = row.value
                        entry.caloriesSource = candidate.source
                        entry.isConfirmedNoIntake = candidate.source == .manual && row.value == 0
                    case proteinKey: entry.proteinG = row.value; entry.macrosSource = candidate.source
                    case carbsKey: entry.carbsG = row.value; entry.macrosSource = candidate.source
                    default: entry.fatG = row.value; entry.macrosSource = candidate.source
                    }
                    byDay[row.day] = entry
                }
            }
        }
        return byDay
    }

    public static func manualNutrition(store: WhoopStore, on day: String) async -> ManualNutritionEntry? {
        func value(_ key: String) async -> Double? {
            (try? await store.metricSeries(deviceId: manualIntakeSource, key: key, from: day, to: day))?.first?.value
        }
        guard await value(loggedKey) != nil, let calories = await value(caloriesKey) else { return nil }
        return .init(day: day, calories: calories, proteinG: await value(proteinKey), carbsG: await value(carbsKey),
                     fatG: await value(fatKey), isConfirmedNoIntake: calories == 0)
    }

    /// Replace one manual day's aggregate and read it back before claiming success.
    public static func recordManualNutrition(store: WhoopStore, _ entry: ManualNutritionEntry) async -> Bool {
        guard entry.calories.isFinite, entry.calories >= 0, entry.calories < 20_000,
              entry.isConfirmedNoIntake == (entry.calories == 0),
              !entry.isConfirmedNoIntake || [entry.proteinG, entry.carbsG, entry.fatG].allSatisfy({ $0 == nil }),
              [entry.proteinG, entry.carbsG, entry.fatG].allSatisfy({ value in
                  value.map { $0.isFinite && $0 >= 0 && $0 < 5_000 } ?? true
              }) else { return false }
        var rows = [MetricPoint(day: entry.day, key: caloriesKey, value: entry.calories),
                    MetricPoint(day: entry.day, key: loggedKey, value: 1)]
        rows += [(proteinKey, entry.proteinG), (carbsKey, entry.carbsG), (fatKey, entry.fatG)].compactMap { key, value in
            value.map { MetricPoint(day: entry.day, key: key, value: $0) }
        }
        do {
            try await store.replaceMetricSeriesWindow(rows, deviceId: manualIntakeSource, keys: keys, from: entry.day, to: entry.day)
            return await manualNutrition(store: store, on: entry.day) == entry
        } catch {
            return false
        }
    }

    /// Removes a manually entered day. Only NOOP's own source is touched.
    public static func deleteIntake(store: WhoopStore, on day: String) async -> Bool {
        do {
            try await store.replaceMetricSeriesWindow([], deviceId: manualIntakeSource, keys: keys, from: day, to: day)
            return await manualNutrition(store: store, on: day) == nil
        } catch {
            return false
        }
    }

    /// The balance estimate over the logged intake and the weigh-ins, up to yesterday.
    /// The energy page's food-and-weight figure, from the one scale estimate (`ScaleBurn`, owner decision
    /// 2026-11-27, Q20): the days marked as completely logged and the weigh-ins without a water mark over eight
    /// weeks, at what a kilogram is worth for this body (`kcalPerKg`, `EnergyDensityResolver`). Kept in the shape the
    /// energy page and the coach already read; nil while the scale cannot say enough yet.
    public static func adaptiveEstimate(reader: StoreReader, asOf: Date = Date(),
                                        healthSourceNames: [String: String] = [:],
                                        kcalPerKg: Double = DietTargets.defaultKcalPerKg) async -> AdaptiveExpenditureEstimate? {
        let today = StoreReader.localDayKey(asOf)
        let from = WeightSeries.date(forDay: today)
            .flatMap { Calendar.current.date(byAdding: .day, value: -ScaleBurn.windowDays, to: $0) }
            .map(StoreReader.localDayKey) ?? today
        let complete = (try? await reader.store.foodCompleteDays(from: from, to: today)) ?? []
        let intake = await nutritionByDay(store: reader.store, from: from, to: today, healthSourceNames: healthSourceNames)
            .compactMapValues(\.calories).filter { complete.contains($0.key) }
        guard !intake.isEmpty else { return nil }
        let series = await WeightSeries.series(reader: reader, from: from, to: today)
        let entries = (try? await reader.store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId, from: from, to: today)) ?? []
        let marked = Set(entries.filter { $0.waterMark != nil }.map(\.day))
        let weighIns = series.filter { !marked.contains($0.day) }.map { (day: $0.day, kg: $0.value) }
        guard case .estimate(let e) = ScaleBurn.estimate(completeIntake: intake, weighIns: weighIns, strapByDay: [:],
                                                         today: today, kcalPerKg: kcalPerKg) else { return nil }
        let eaten = intake.values.reduce(0, +) / Double(intake.count)
        let half = 1.96 * e.errorKcal
        return AdaptiveExpenditureEstimate(
            estimatedDailyKcal: e.burnKcal, lowerBoundKcal: max(0, e.burnKcal - half), upperBoundKcal: e.burnKcal + half,
            averageCaloriesIn: eaten, weightChangeKgPerDay: e.trendKgPerWeek / 7, intakeDays: e.completeDays,
            weightReadings: e.weighIns, windowDays: ScaleBurn.windowDays,
            intakeCoverage: Double(e.completeDays) / Double(ScaleBurn.windowDays),
            confidence: e.relativeError <= 0.05 ? .high : .moderate)
    }
}
