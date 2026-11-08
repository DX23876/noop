import Foundation
import WhoopStore

/// Reference intakes for adults, from the EFSA Dietary Reference Values (population reference intakes where EFSA
/// set one, adequate intakes otherwise), plus WHO's limits for salt and saturated fat. The values describe
/// HABITUAL intake, so every screen compares a seven-day average with them, never a single day.
public enum FoodReference {
    public enum Kind: String, Sendable, Codable {
        /// Reach at least this much on average.
        case atLeast
        /// Stay below this on average.
        case atMost
    }

    public struct Value: Equatable, Sendable, Codable {
        public var amount: Double
        public var kind: Kind
        /// Where the number comes from, for the info line.
        public var source: String
    }

    public enum Sex: String, Sendable { case female, male }

    /// From the profile's sex ("male", "female", anything else). Without one, each reference takes the stricter
    /// of the two: the higher intake to reach, the lower limit to stay under.
    public static func values(profileSex: String, age: Int, weightKg: Double?, heightCm: Double?, energyKcal: Double?)
        -> [FoodNutrient: Value] {
        if let sex = Sex(rawValue: profileSex.lowercased()) {
            return values(sex: sex, age: age, weightKg: weightKg, heightCm: heightCm, energyKcal: energyKcal)
        }
        let f = values(sex: .female, age: age, weightKg: weightKg, heightCm: heightCm, energyKcal: energyKcal)
        let m = values(sex: .male, age: age, weightKg: weightKg, heightCm: heightCm, energyKcal: energyKcal)
        return f.merging(m) { a, b in a.kind == .atLeast ? (a.amount >= b.amount ? a : b) : (a.amount <= b.amount ? a : b) }
    }

    /// The references for one person. Energy-scaled vitamins (thiamin, niacin) use the day's calorie goal; protein
    /// uses the weight at a BMI of 25 when the person weighs more, since protein need follows lean mass rather than
    /// total weight (EFSA's 0.83 g/kg was set for normal-weight adults).
    public static func values(sex: Sex, age: Int, weightKg: Double?, heightCm: Double?, energyKcal: Double?)
        -> [FoodNutrient: Value] {
        let female = sex == .female
        let efsa = "EFSA"
        var out: [FoodNutrient: Value] = [
            .fiberG: .init(amount: 30, kind: .atLeast, source: "Reynolds 2019, EFSA 25 g"),
            .epaG: .init(amount: 0.25, kind: .atLeast, source: "EFSA (EPA plus DHA)"),
            .saltG: .init(amount: 5, kind: .atMost, source: "WHO"),
            .sodiumMg: .init(amount: 2_000, kind: .atMost, source: efsa),
            .potassiumMg: .init(amount: 3_500, kind: .atLeast, source: efsa),
            .calciumMg: .init(amount: age < 25 ? 1_000 : 950, kind: .atLeast, source: efsa),
            .magnesiumMg: .init(amount: female ? 300 : 350, kind: .atLeast, source: efsa),
            .phosphorusMg: .init(amount: 550, kind: .atLeast, source: efsa),
            .ironMg: .init(amount: female && age < 50 ? 16 : 11, kind: .atLeast, source: efsa),
            .zincMg: .init(amount: female ? 9.3 : 11.7, kind: .atLeast, source: "EFSA (phytate 600 mg)"),
            .iodineUg: .init(amount: 150, kind: .atLeast, source: efsa),
            .copperMg: .init(amount: female ? 1.3 : 1.6, kind: .atLeast, source: efsa),
            .manganeseMg: .init(amount: 3, kind: .atLeast, source: efsa),
            .vitaminAUg: .init(amount: female ? 650 : 750, kind: .atLeast, source: efsa),
            .vitaminDUg: .init(amount: 15, kind: .atLeast, source: efsa),
            .vitaminEMg: .init(amount: female ? 11 : 13, kind: .atLeast, source: efsa),
            .vitaminKUg: .init(amount: 70, kind: .atLeast, source: efsa),
            .riboflavinMg: .init(amount: 1.6, kind: .atLeast, source: efsa),
            .vitaminB6Mg: .init(amount: female ? 1.6 : 1.7, kind: .atLeast, source: efsa),
            .folateUg: .init(amount: 330, kind: .atLeast, source: efsa),
            .vitaminB12Ug: .init(amount: 4, kind: .atLeast, source: efsa),
            .vitaminCMg: .init(amount: female ? 95 : 110, kind: .atLeast, source: efsa),
            .pantothenicMg: .init(amount: 5, kind: .atLeast, source: efsa),
            .biotinUg: .init(amount: 40, kind: .atLeast, source: efsa),
        ]
        // Thiamin 0.1 mg and niacin 1.6 mg per MJ of energy (EFSA), at the day's goal or 2,000 kcal.
        let megajoules = (energyKcal ?? 2_000) * 4.184 / 1_000
        out[.thiaminMg] = .init(amount: 0.1 * megajoules, kind: .atLeast, source: efsa)
        out[.niacinMg] = .init(amount: 1.6 * megajoules, kind: .atLeast, source: efsa)
        if let weightKg, weightKg > 0 {
            var reference = weightKg
            if let heightCm, heightCm > 0 { reference = min(weightKg, 25 * pow(heightCm / 100, 2)) }
            out[.proteinG] = .init(amount: 0.83 * reference, kind: .atLeast, source: "EFSA 0.83 g/kg")
        }
        if let energyKcal {
            // WHO: saturated fat below 10 % of energy, 9 kcal per gram.
            out[.satFatG] = .init(amount: energyKcal * 0.10 / 9, kind: .atMost, source: "WHO")
        }
        return out
    }
}

/// The nutrients of the last days against the references: what the Food page's nutrient card and the nutrient page
/// show on both platforms, computed once here.
public enum FoodNutrientReport {
    public struct Row: Equatable, Sendable, Codable {
        public var nutrient: FoodNutrient
        /// Average per logged day over the window.
        public var average: Double
        public var today: Double
        public var reference: FoodReference.Value?
        /// Share of the window's logged energy that came from entries knowing this nutrient (0 to 1).
        public var coverage: Double
        /// Share of this nutrient's amount that was estimated from a similar BLS food (0 to 1).
        public var estimatedShare: Double
        /// The foods that gave the most of it, largest first, with their amount over the window.
        public var topFoods: [Source]
        public var status: Status

        public struct Source: Equatable, Sendable, Codable { public var name: String; public var amount: Double }
    }

    public enum Status: String, Sendable, Codable {
        /// Within the reference (at least reached, or below a limit).
        case fine
        /// Below an intake reference, or above a limit.
        case attention
        /// Too little of the logged food states this nutrient to judge.
        case incomplete
        /// No reference for it.
        case none
    }

    public struct Report: Equatable, Sendable, Codable {
        public var from: String
        public var to: String
        public var loggedDays: Int
        public var rows: [Row]

        public var fineCount: Int { rows.filter { $0.status == .fine }.count }
        public var judgedCount: Int { rows.filter { $0.status == .fine || $0.status == .attention }.count }
    }

    /// Below this share of logged energy, a nutrient's average is not judged.
    public static let minimumCoverage = 0.7
    public static let windowDays = 7

    /// The report for the `windowDays` up to `to`, from the stored entries; days without entries are not
    /// counted as days of eating nothing.
    public static func report(store: WhoopStore, to day: String, references: [FoodNutrient: FoodReference.Value]) async -> Report {
        let end = WeightSeries.date(forDay: day) ?? Date()
        let start = Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: end) ?? end
        let from = StoreReader.localDayKey(start)
        let entries = (try? await store.foodLogEntries(from: from, to: day)) ?? []
        return report(entries: entries, from: from, to: day, references: references)
    }

    public static func report(entries: [FoodLogEntry], from: String, to: String,
                              references: [FoodNutrient: FoodReference.Value]) -> Report {
        let days = Set(entries.map(\.day))
        let loggedDays = max(1, days.count)
        let energy = entries.reduce(0) { $0 + ($1.totals["energy_kcal"] ?? 0) }
        let shown = FoodNutrient.allCases.filter { ![.energyKcal, .waterG, .alcoholG, .dhaG].contains($0) }
        let rows: [Row] = shown.map { nutrient in
            var total = 0.0, today = 0.0, knownEnergy = 0.0, estimated = 0.0
            var byFood: [String: Double] = [:]
            for entry in entries {
                // EPA's row is EPA plus DHA together: that sum is what the reference is about.
                let raw = nutrient == .epaG
                    ? (entry.totals["epa_g"] ?? entry.totals["dha_g"]).map { _ in (entry.totals["epa_g"] ?? 0) + (entry.totals["dha_g"] ?? 0) }
                    : entry.totals[nutrient.rawValue]
                guard let value = raw else { continue }
                total += value
                if entry.estimatedKeys.contains(nutrient.rawValue) { estimated += value }
                knownEnergy += entry.totals["energy_kcal"] ?? 0
                if entry.day == to { today += value }
                byFood[entry.name, default: 0] += value
            }
            let coverage = energy > 0 ? knownEnergy / energy : (total > 0 ? 1 : 0)
            let average = total / Double(loggedDays)
            let reference = references[nutrient]
            let status: Status
            if let reference {
                if coverage < minimumCoverage || days.isEmpty {
                    status = .incomplete
                } else {
                    switch reference.kind {
                    case .atLeast: status = average >= reference.amount ? .fine : .attention
                    case .atMost: status = average <= reference.amount ? .fine : .attention
                    }
                }
            } else {
                status = .none
            }
            let top = byFood.sorted { $0.value > $1.value }.prefix(5).filter { $0.value > 0 }
                .map { Row.Source(name: $0.key, amount: $0.value) }
            return Row(nutrient: nutrient, average: average, today: today, reference: reference, coverage: coverage,
                       estimatedShare: total > 0 ? estimated / total : 0, topFoods: top, status: status)
        }
        return Report(from: from, to: to, loggedDays: days.count, rows: rows)
    }

    /// The groups the nutrient page shows, in this order.
    public static let groups: [(name: String, nutrients: [FoodNutrient])] = [
        ("macros", [.proteinG, .fiberG, .sugarG, .satFatG, .monoFatG, .polyFatG, .omega3G, .epaG, .cholesterolMg]),
        ("minerals", [.saltG, .sodiumMg, .potassiumMg, .calciumMg, .magnesiumMg, .phosphorusMg, .ironMg, .zincMg,
                      .iodineUg, .copperMg, .manganeseMg]),
        ("vitamins", [.vitaminAUg, .vitaminDUg, .vitaminEMg, .vitaminKUg, .thiaminMg, .riboflavinMg, .niacinMg,
                      .vitaminB6Mg, .folateUg, .vitaminB12Ug, .vitaminCMg, .pantothenicMg, .biotinUg]),
    ]
}
