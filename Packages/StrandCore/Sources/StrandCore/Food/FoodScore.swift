import Foundation
import WhoopStore

/// How healthy the week's eating was, 0 to 100, after the Alternate Healthy Eating Index 2010 with the owner's
/// choices of 2026-11-08 (`backlog/research/nutrition-score/README.md`): no alcohol scores full, sodium on fixed
/// limits instead of study deciles, trans fat left out for lack of data, fixed portion sizes, highly processed
/// food shown beside the score instead of inside it, and no score below five logged days of seven.
///
/// The index describes habitual eating, so it is computed over the last seven days, never for one day, and
/// averaged over the days that carry a log. It is read at view time; nothing is stored.
public enum FoodScore {
    public enum Component: String, CaseIterable, Sendable, Codable {
        case vegetables, fruit, wholeGrains, sugaryDrinks, nutsLegumes, redMeat, fishOmega3, polyFats, sodium, alcohol
    }

    public struct Part: Equatable, Sendable, Codable {
        public var component: Component
        /// 0 to 10.
        public var points: Double
        /// The daily amount the points came from, in the component's own unit (portions, grams, mg, % energy).
        public var amountPerDay: Double
    }

    public struct Result: Equatable, Sendable, Codable {
        /// 0 to 100.
        public var score: Double
        public var parts: [Part]
        public var loggedDays: Int
        /// Share of the week's calories from highly processed foods (NOVA 4), when any logged food knew its class.
        public var processedShare: Double?
    }

    /// What the score needs to know about a food beyond its entry: its stored group and NOVA class.
    public struct FoodFacts: Equatable, Sendable {
        public var group: String?
        public var nova: Int?
        public init(group: String? = nil, nova: Int? = nil) { self.group = group; self.nova = nova }
    }

    public static let window = 7
    public static let minimumDays = 5
    /// The Lab switch: the score shows only after the wearer turns it on (decision 2026-11-08).
    public static let enabledKey = "food.score.enabled"

    /// Portion sizes in grams (or millilitres for drinks).
    public enum Portion {
        public static let vegetables = 80.0, fruit = 80.0, nuts = 28.0, legumes = 80.0, meat = 85.0, drink = 250.0
    }

    /// Nil when fewer than `minimumDays` of the `window` days ending on `lastDay` carry a log.
    /// `facts` maps a food id to what the entry itself does not say; BLS ids carry their group in the code.
    public static func week(entries: [FoodLogEntry], lastDay: String, facts: [String: FoodFacts] = [:],
                            male: Bool?, calendar: Calendar = .current) -> Result? {
        guard let end = WeightSeries.date(forDay: lastDay),
              let start = calendar.date(byAdding: .day, value: -(window - 1), to: end) else { return nil }
        let first = StoreReader.localDayKey(start)
        let week = entries.filter { $0.day >= first && $0.day <= lastDay }
        let days = Set(week.map(\.day)).count
        guard days >= minimumDays else { return nil }
        return score(week, days: Double(days), facts: facts, male: male)
    }

    static func score(_ entries: [FoodLogEntry], days: Double, facts: [String: FoodFacts], male: Bool?) -> Result {
        var grams: [Component: Double] = [:]
        var nuts = 0.0, legumes = 0.0, sugaryDrinks = 0.0
        var total = NutrientAmounts()
        var processedKcal = 0.0, novaKnownKcal = 0.0
        for entry in entries {
            let amounts = NutrientAmounts(stored: entry.totals)
            total = total + amounts
            let kcal = amounts[.energyKcal] ?? 0
            let info = entry.foodId.flatMap { facts[$0] }
            if let nova = info?.nova {
                novaKnownKcal += kcal
                if nova == 4 { processedKcal += kcal }
            }
            guard let g = entry.grams, g > 0 else { continue }
            let name = entry.name.lowercased()
            switch kind(of: entry, group: info?.group, name: name) {
            case .vegetables: grams[.vegetables, default: 0] += g
            case .fruit: grams[.fruit, default: 0] += g
            case .nuts: nuts += g
            case .legumes: legumes += g
            case .redMeat: grams[.redMeat, default: 0] += g
            case .drink:
                // A drink counts as sugary from 2.5 g sugar per 100 ml (sweetened drinks and juices, not water or tea).
                if let per100 = entry.per100g?["sugar_g"], per100 >= 2.5 { sugaryDrinks += g }
            case nil: break
            }
            if wholeGrainWords.contains(where: name.contains) { grams[.wholeGrains, default: 0] += g }
        }
        let kcal = max(1, total[.energyKcal] ?? 0)
        let sodium = total[.sodiumMg] ?? (total[.saltG].map { $0 * 400 } ?? 0)
        let omega3Mg = ((total[.epaG] ?? 0) + (total[.dhaG] ?? 0)) * 1_000
        let polyShare = (total[.polyFatG] ?? 0) * 9 / kcal * 100
        let wholeGrainGoal = male == true ? 90.0 : 75.0
        let drinksUpper = male == true ? 3.5 : 2.5

        let perDay: [(Component, Double)] = [
            (.vegetables, grams[.vegetables, default: 0] / Portion.vegetables / days),
            (.fruit, grams[.fruit, default: 0] / Portion.fruit / days),
            (.wholeGrains, grams[.wholeGrains, default: 0] / days),
            (.sugaryDrinks, sugaryDrinks / Portion.drink / days),
            (.nutsLegumes, (nuts / Portion.nuts + legumes / Portion.legumes) / days),
            (.redMeat, grams[.redMeat, default: 0] / Portion.meat / days),
            (.fishOmega3, omega3Mg / days),
            (.polyFats, polyShare),
            (.sodium, sodium / days),
            (.alcohol, (total[.alcoholG] ?? 0) / 14 / days),
        ]
        let parts = perDay.map { component, amount -> Part in
            let points: Double
            switch component {
            case .vegetables: points = more(amount, full: 5)
            case .fruit: points = more(amount, full: 4)
            case .wholeGrains: points = more(amount, full: wholeGrainGoal)
            case .sugaryDrinks: points = less(amount, best: 0, worst: 1)
            case .nutsLegumes: points = more(amount, full: 1)
            case .redMeat: points = less(amount, best: 0, worst: 1.5)
            case .fishOmega3: points = more(amount, full: 250)
            case .polyFats: points = between(amount, zeroAt: 2, fullAt: 10)
            case .sodium: points = less(amount, best: 1_500, worst: 4_000)
            case .alcohol: points = less(amount, best: 0, worst: drinksUpper)
            }
            return Part(component: component, points: points, amountPerDay: amount)
        }
        let score = parts.reduce(0) { $0 + $1.points } / Double(parts.count * 10) * 100
        return Result(score: score, parts: parts, loggedDays: Int(days),
                      processedShare: novaKnownKcal > 0 ? processedKcal / novaKnownKcal : nil)
    }

    /// 10 points at `full` or more, linear down to 0 at none.
    static func more(_ value: Double, full: Double) -> Double { min(10, max(0, value / full * 10)) }
    /// 10 points at `best` or less, linear down to 0 at `worst` or more.
    static func less(_ value: Double, best: Double, worst: Double) -> Double {
        guard value > best else { return 10 }
        return max(0, 10 * (worst - value) / (worst - best))
    }
    /// 0 points at `zeroAt` or less, 10 at `fullAt` or more.
    static func between(_ value: Double, zeroAt: Double, fullAt: Double) -> Double {
        min(10, max(0, (value - zeroAt) / (fullAt - zeroAt) * 10))
    }

    enum Kind { case vegetables, fruit, nuts, legumes, redMeat, drink }

    static let wholeGrainWords = ["vollkorn", "whole grain", "wholegrain", "whole wheat", "wholemeal"]
    static let juiceWords = ["saft", "juice", "nektar", "nectar", "smoothie"]
    static let nutWords = ["nuss", "nüsse", "mandel", "nut", "almond", "kern", "seed", "samen", "pistazie", "pistachio"]

    /// Which component group a food falls in: BLS letters first (potatoes are not vegetables, juice is a drink and
    /// not fruit, poultry is not red meat), then the Open Food Facts group, then words in the name.
    static func kind(of entry: FoodLogEntry, group: String?, name: String) -> Kind? {
        if let id = entry.foodId, id.hasPrefix("bls:"), let letter = id.dropFirst(4).first.map({ String($0).lowercased() }) {
            switch letter {
            case "g": return .vegetables
            case "f": return juiceWords.contains(where: name.contains) ? .drink : .fruit
            case "h": return nutWords.contains(where: name.contains) ? .nuts : .legumes
            case "u", "w": return poultryWords.contains(where: name.contains) ? nil : .redMeat
            case "n": return .drink
            default: return nil
            }
        }
        guard let raw = group?.lowercased(), !raw.isEmpty else { return nil }
        if ["juice", "nectar", "beverage"].contains(where: raw.contains) { return .drink }
        if raw.contains("vegetable") { return .vegetables }
        if raw.contains("fruit") && !raw.contains("dried") { return .fruit }
        if raw.contains("nut") { return .nuts }
        if raw.contains("legume") { return .legumes }
        if raw.contains("processed-meat") || (raw.contains("meat") && !poultryWords.contains(where: name.contains)) { return .redMeat }
        return nil
    }

    static let poultryWords = ["huhn", "hähnchen", "hühn", "pute", "truthahn", "geflügel", "ente", "gans", "chicken", "turkey", "poultry", "duck"]
}
