import Foundation
import StrandAnalytics
import WhoopStore

/// One day's resolved nutrition: each field from the most deliberate source that logged it.
public struct NutritionDay: Equatable, Sendable {
    public enum Source: String, Sendable { case appleHealth, csv, manual }

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
/// (parity plan 2.3). Apple Health first, a CSV import over it, a typed value over both, field by field.
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

    /// Resolve nutrition per field. A deliberate manual correction wins only the field it contains; its absent
    /// macros continue to use the imported values instead of being erased.
    public static func nutritionByDay(store: WhoopStore, from: String, to: String,
                                      healthSourceNames: [String: String] = [:]) async -> [String: NutritionDay] {
        let sources: [(id: String, source: NutritionDay.Source)] = [
            (MetricResolver.appleHealthSource, .appleHealth), (csvIntakeSource, .csv), (manualIntakeSource, .manual),
        ]
        var byDay: [String: NutritionDay] = [:]
        for candidate in sources {
            let markerDays = Set(((try? await store.metricSeries(
                deviceId: candidate.id, key: loggedKey, from: from, to: to)) ?? []).map(\.day))
            for key in [caloriesKey, proteinKey, carbsKey, fatKey] {
                let rows = (try? await store.metricSeries(deviceId: candidate.id, key: key, from: from, to: to)) ?? []
                for row in rows where row.value > 0 || (candidate.source == .manual && markerDays.contains(row.day)) {
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
    public static func adaptiveEstimate(reader: StoreReader, asOf: Date = Date(),
                                        healthSourceNames: [String: String] = [:]) async -> AdaptiveExpenditureEstimate? {
        let calendar = Calendar.current
        let cutoff = calendar.startOfDay(for: asOf)
        guard let firstDate = calendar.date(byAdding: .day, value: -(AdaptiveExpenditureEngine.maximumWindowDays + 1), to: cutoff),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: cutoff) else { return nil }
        let from = StoreReader.localDayKey(firstDate)
        let to = StoreReader.localDayKey(yesterday)
        let intake = await nutritionByDay(store: reader.store, from: from, to: to, healthSourceNames: healthSourceNames)
            .compactMapValues(\.calories)
        guard !intake.isEmpty else { return nil }
        let weights = await WeightSeries.series(reader: reader,
            from: StoreReader.localDayKey(asOf.addingTimeInterval(-Double(AdaptiveExpenditureEngine.maximumWindowDays + 2) * 86_400)),
            to: StoreReader.localDayKey(asOf))
        var byDay: [String: (calories: Double?, weight: Double?)] = [:]
        for (day, kcal) in intake where day >= from && day <= to { byDay[day, default: (nil, nil)].calories = kcal }
        for point in weights where point.day >= from && point.day <= to { byDay[point.day, default: (nil, nil)].weight = point.value }
        let inputs = byDay.compactMap { day, values -> AdaptiveExpenditureDay? in
            guard let date = WeightSeries.date(forDay: day) else { return nil }
            return .init(date: date, caloriesIn: values.calories, weightKg: values.weight)
        }
        return AdaptiveExpenditureEngine.estimate(days: inputs, asOf: asOf, calendar: calendar)
    }
}
