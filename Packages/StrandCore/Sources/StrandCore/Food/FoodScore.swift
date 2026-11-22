import Foundation
import WhoopStore

/// How healthy the week's eating was, 0 to 100 (owner, 2026-11-22, `backlog/research/nutrition-score/README.md`).
///
/// It started as the Alternate Healthy Eating Index 2010 and is no longer it, so it is called nutrition quality
/// and not the index's name. What it keeps from the index: the parts, their portion sizes and their daily
/// targets. What it takes from Bevel's food quality contributors (owner, 2026-11-22): points are earned and lost
/// around a neutral middle instead of averaged, so a food the log cannot place costs nothing instead of pulling
/// a part to zero.
///
/// - `base` is a neutral day. Five positive parts add up to 10 points each, six limits take points off, and the
///   sum is clamped to 0...100. All good is 100, all bad is 0.
/// - Free sugar replaces the index's sweet-drinks part, so a cola is counted once, in grams rather than as a
///   drink (owner, 2026-11-22).
/// - Saturated fat replaces the index's polyunsaturated-fat part: mono plus poly over a fifth of the energy is
///   met by any fat-rich day and so says nothing, while saturated fat moves with what is eaten.
/// - Red and processed meat are two parts, since their evidence differs; red meat is the one part worth half.
/// - Salt keeps falling past its first threshold instead of stopping there, so a day at three times the limit
///   cannot read like a day at the limit. A sweat allowance shifts both thresholds (`FoodSweat`).
///
/// The index describes habitual eating, so a week or a month adds the amounts up and scores them once; a day
/// reads the few-times-a-week foods over the seven days ending on it (`FoodQuality`). It is read at view time;
/// nothing is stored.
public enum FoodScore {
    /// A neutral day, before anything is earned or lost.
    public static let base = 50.0

    public enum Component: String, CaseIterable, Sendable, Codable {
        case vegetables, fruit, wholeGrains, nutsLegumes, fishOmega3
        case freeSugar, satFat, sodium, redMeat, processedMeat, alcohol
        /// Fibre in place of whole grains for the forms that leave grains out (keto, low carb; owner, 2026-11-21):
        /// whole grains count for their fibre, and fibre also comes from vegetables, nuts and seeds.
        case fiber

        /// Foods eaten a few times a week rather than daily. A day's note reads them over the last seven days,
        /// so a day without fish is not a bad day and a steak weighs on the week (owner, 2026-11-21).
        public var isWeekly: Bool { [.nutsLegumes, .redMeat, .processedMeat, .fishOmega3].contains(self) }

        /// A part that takes points off instead of adding them.
        public var isLimit: Bool { [.freeSugar, .satFat, .sodium, .redMeat, .processedMeat, .alcohol].contains(self) }

        /// The most this part can add (a positive part) or take off (a limit). Red meat is worth half: the owner
        /// held its evidence to be weaker than processed meat's (2026-11-21), and Bevel weighs it the same way.
        public var weight: Double { self == .redMeat ? 5 : 10 }
    }

    /// One part of the score.
    public struct Part: Equatable, Sendable, Codable {
        public var component: Component
        /// The part's signed contribution: 0 to `component.weight` for a positive part, 0 to minus that for a
        /// limit. A screen can show it as it stands, with no second rule about which way a part counts.
        public var points: Double
        /// The daily amount the points came from, in the component's own unit (portions, grams, mg, % energy).
        public var amountPerDay: Double

        public init(component: Component, points: Double, amountPerDay: Double) {
            self.component = component; self.points = points; self.amountPerDay = amountPerDay
        }
    }

    public struct Result: Equatable, Sendable, Codable {
        /// 0 to 100.
        public var score: Double
        public var parts: [Part]
        public var loggedDays: Int
        /// Share of the week's calories from highly processed foods (NOVA 4), when any logged food knew its class.
        public var processedShare: Double?
    }

    /// The groups a food's weight can fall into, for the parts that count food rather than a nutrient.
    public enum Group: String, CaseIterable, Sendable, Codable, Hashable {
        case vegetables, fruit, nuts, legumes, redMeat, processedMeat, drink
    }

    /// What the score needs to know about a food beyond its entry: its stored group and NOVA class, and what the
    /// coach or the wearer worked out about it (`FoodClassification`).
    public struct FoodFacts: Equatable, Sendable {
        public var group: String?
        public var nova: Int?
        /// The food's weight split over groups, each 0 to 1 (at most three). Set, it replaces `group`, so a
        /// granola can be part cereal and part seeds.
        public var shares: [Group: Double]?
        /// Share of the food's weight that is whole-grain cereal. Nil falls back to the name.
        public var wholeGrainShare: Double?
        /// Share of the food's sugar that is free sugar as the WHO means it: added sugar, honey, syrup and the
        /// sugar in juice, but not the sugar in milk or whole fruit. Nil falls back to the drink rule.
        public var freeSugarShare: Double?

        public init(group: String? = nil, nova: Int? = nil, shares: [Group: Double]? = nil,
                    wholeGrainShare: Double? = nil, freeSugarShare: Double? = nil) {
            self.group = group; self.nova = nova; self.shares = shares
            self.wholeGrainShare = wholeGrainShare; self.freeSugarShare = freeSugarShare
        }
    }

    public static let window = 7
    public static let minimumDays = 5

    /// The meat and fibre limits of the owner's choices of 2026-11-21.
    public enum Meat {
        /// Unprocessed red meat costs nothing up to this much a week (WCRF: limit to 350 to 500 g cooked a week).
        public static let redFreeWeekG = 350.0
        /// And the part is spent at twice the WCRF's upper end.
        public static let redZeroWeekG = 1_000.0
        /// Fibre for full points, the DGE's 30 g a day.
        public static let fiberFullG = 30.0
    }

    /// Where the limits start to cost and where they are spent.
    public enum Limit {
        /// Free sugar: nothing up to the WHO's ideal of 5 % of the energy, the full cost at its upper 10 %.
        public static let freeSugarIdealPercent = 5.0, freeSugarMaxPercent = 10.0
        /// Saturated fat: nothing up to the WHO's 10 % of the energy, the full cost at three times that. The
        /// upper end is wide on purpose: at 20 % a day of cheese and eggs already sits at the full cost, and a
        /// part that never moves says nothing about what changed.
        public static let satFatIdealPercent = 10.0, satFatMaxPercent = 30.0
        /// Salt: nothing up to 1,500 mg sodium, half the cost at 2,300 mg, the full cost at 4,000 mg.
        public static let sodiumFreeMg = 1_500.0, sodiumHalfMg = 2_300.0, sodiumMaxMg = 4_000.0
    }

    /// Portion sizes in grams (or millilitres for drinks).
    public enum Portion {
        public static let vegetables = 80.0, fruit = 80.0, nuts = 28.0, legumes = 80.0, meat = 85.0, drink = 250.0
    }

    /// Nil when fewer than `minimumDays` of the `window` days ending on `lastDay` carry a log.
    /// `facts` maps a food id to what the entry itself does not say; BLS ids carry their group in the code.
    public static func week(entries: [FoodLogEntry], lastDay: String, facts: [String: FoodFacts] = [:],
                            male: Bool?, options: Options = .init(), sweatSodiumMg: Double = 0,
                            calendar: Calendar = .current) -> Result? {
        guard let end = WeightSeries.date(forDay: lastDay),
              let start = calendar.date(byAdding: .day, value: -(window - 1), to: end) else { return nil }
        let first = StoreReader.localDayKey(start)
        let week = entries.filter { $0.day >= first && $0.day <= lastDay }
        let days = Set(week.map(\.day)).count
        guard days >= minimumDays else { return nil }
        return score(week, days: Double(days), facts: facts, male: male, options: options,
                     sweatSodiumMg: sweatSodiumMg)
    }

    /// How the parts are read beyond the index itself (owner, 2026-11-21, `backlog/ideas/food-score-coach-2026-11-21.md`).
    public struct Options: Equatable, Sendable {
        /// Keto and low carb trade whole grains for fibre.
        public var fiberForGrains: Bool
        public init(fiberForGrains: Bool = false) { self.fiberForGrains = fiberForGrains }

        public static func forDiet(_ form: DietForm?) -> Options {
            Options(fiberForGrains: form == .keto || form == .lowCarb)
        }
    }

    /// The weekly foods' amounts for a score whose other parts come from fewer days (the day's note).
    struct WeeklyFoods {
        var meatProcessedG = 0.0, meatRedG = 0.0, nutsG = 0.0, legumesG = 0.0, omega3Mg = 0.0
        var days = 1.0
    }

    static func weeklyFoods(_ entries: [FoodLogEntry], days: Double, facts: [String: FoodFacts]) -> WeeklyFoods {
        var out = WeeklyFoods(days: max(1, days))
        for entry in entries {
            let amounts = NutrientAmounts(stored: entry.totals)
            out.omega3Mg += ((amounts[.epaG] ?? 0) + (amounts[.dhaG] ?? 0)) * 1_000
            guard let g = entry.grams, g > 0 else { continue }
            for (group, share) in groups(of: entry, facts: facts) {
                switch group {
                case .processedMeat: out.meatProcessedG += g * share
                case .redMeat: out.meatRedG += g * share
                case .nuts: out.nutsG += g * share
                case .legumes: out.legumesG += g * share
                default: break
                }
            }
        }
        return out
    }

    static func score(_ entries: [FoodLogEntry], days: Double, facts: [String: FoodFacts], male: Bool?,
                      options: Options = .init(), weekly: WeeklyFoods? = nil,
                      sweatSodiumMg: Double = 0) -> Result {
        var grams: [Group: Double] = [:]
        var wholeGrainG = 0.0, freeSugarG = 0.0
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
            let placed = groups(of: entry, facts: facts)
            freeSugarG += (amounts[.sugarG] ?? 0) * freeSugarShare(entry, facts: info, groups: placed)
            guard let g = entry.grams, g > 0 else { continue }
            for (group, share) in placed { grams[group, default: 0] += g * share }
            wholeGrainG += g * wholeGrainShare(entry, facts: info)
        }
        let kcal = max(1, total[.energyKcal] ?? 0)
        let sodium = total[.sodiumMg] ?? (total[.saltG].map { $0 * 400 } ?? 0)
        let own = WeeklyFoods(meatProcessedG: grams[.processedMeat, default: 0], meatRedG: grams[.redMeat, default: 0],
                              nutsG: grams[.nuts, default: 0], legumesG: grams[.legumes, default: 0],
                              omega3Mg: ((total[.epaG] ?? 0) + (total[.dhaG] ?? 0)) * 1_000, days: days)
        let w = weekly ?? own
        let wholeGrainGoal = male == true ? 90.0 : 75.0
        let drinksUpper = male == true ? 3.5 : 2.5

        let perDay: [(Component, Double)] = [
            (.vegetables, grams[.vegetables, default: 0] / Portion.vegetables / days),
            (.fruit, grams[.fruit, default: 0] / Portion.fruit / days),
            options.fiberForGrains ? (.fiber, (total[.fiberG] ?? 0) / days) : (.wholeGrains, wholeGrainG / days),
            (.nutsLegumes, (w.nutsG / Portion.nuts + w.legumesG / Portion.legumes) / w.days),
            (.fishOmega3, w.omega3Mg / w.days),
            (.freeSugar, freeSugarG * 4 / kcal * 100),
            (.satFat, (total[.satFatG] ?? 0) * 9 / kcal * 100),
            (.sodium, sodium / days),
            (.redMeat, w.meatRedG / w.days),
            (.processedMeat, w.meatProcessedG / w.days / Portion.meat),
            (.alcohol, (total[.alcoholG] ?? 0) / 14 / days),
        ]
        let parts = perDay.map { component, amount -> Part in
            let share: Double
            switch component {
            case .vegetables: share = upTo(amount, full: 5)
            case .fruit: share = upTo(amount, full: 4)
            case .wholeGrains: share = upTo(amount, full: wholeGrainGoal)
            case .fiber: share = upTo(amount, full: Meat.fiberFullG)
            case .nutsLegumes: share = upTo(amount, full: 1)
            case .fishOmega3: share = upTo(amount, full: 250)
            case .freeSugar:
                share = -ramp(amount, from: Limit.freeSugarIdealPercent, to: Limit.freeSugarMaxPercent)
            case .satFat:
                share = -ramp(amount, from: Limit.satFatIdealPercent, to: Limit.satFatMaxPercent)
            case .sodium: share = -sodiumCost(amount, allowanceMg: sweatSodiumMg)
            // Unprocessed red meat costs nothing up to the WCRF's 350 g cooked a week, the whole part at twice
            // its 500 g upper end (owner, 2026-11-21).
            case .redMeat: share = -ramp(amount, from: Meat.redFreeWeekG / 7, to: Meat.redZeroWeekG / 7)
            // Processed meat keeps the index's strict curve, where the evidence is strong.
            case .processedMeat: share = -ramp(amount, from: 0, to: 1.5)
            case .alcohol: share = -ramp(amount, from: 0, to: drinksUpper)
            }
            return Part(component: component, points: share * component.weight, amountPerDay: amount)
        }
        let score = (base + parts.reduce(0) { $0 + $1.points }).clamped(0, 100)
        return Result(score: score, parts: parts, loggedDays: Int(days),
                      processedShare: novaKnownKcal > 0 ? processedKcal / novaKnownKcal : nil)
    }

    /// The share of a positive part that is earned: all of it at `full` or more, linear down to none.
    static func upTo(_ value: Double, full: Double) -> Double { (value / full).clamped(0, 1) }

    /// The share of a limit that is spent: none at `from` or less, all of it at `to` or more.
    static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        return ((value - from) / (to - from)).clamped(0, 1)
    }

    /// Salt's cost, as a share of its part: nothing up to 1,500 mg sodium, half at 2,300 mg, all of it at
    /// 4,000 mg. The sweat allowance shifts all three, so a day of hard work is held to the same food, not to
    /// the same number (owner, 2026-11-22).
    static func sodiumCost(_ mg: Double, allowanceMg: Double = 0) -> Double {
        let free = Limit.sodiumFreeMg + allowanceMg, half = Limit.sodiumHalfMg + allowanceMg
        let max = Limit.sodiumMaxMg + allowanceMg
        if mg <= free { return 0 }
        if mg <= half { return 0.5 * ramp(mg, from: free, to: half) }
        return 0.5 + 0.5 * ramp(mg, from: half, to: max)
    }

    /// How much of a food is whole-grain cereal: what the coach or the wearer worked out, else what the name
    /// says. For a branded product the name only catches one that says so, which is why the classification
    /// exists. For a BLS row it is enough, because the BLS names its foods systematically: whole grain is
    /// "Vollkorn" or "ganzes Korn", flakes are rolled whole grain, rice is "unpoliert" or "poliert", and a
    /// flour says its type when it is not wholemeal. So a BLS row needs no model to be read (owner, 2026-11-22).
    static func wholeGrainShare(_ entry: FoodLogEntry, facts: FoodFacts?) -> Double {
        if let share = facts?.wholeGrainShare { return share.clamped(0, 1) }
        let name = entry.name.lowercased()
        if let id = entry.foodId, id.hasPrefix("bls:") { return blsWholeGrainShare(name: name, id: id) }
        return wholeGrainWords.contains(where: name.contains) ? 1 : 0
    }

    /// A BLS row's whole-grain share from its own name, in either language the catalogue carries.
    static func blsWholeGrainShare(name: String, id: String) -> Double {
        // Bran and germ are parts of the grain, not the whole of it, and "Oat bran flakes" would otherwise pass
        // on the word "flakes".
        guard !grainFractionWords.contains(where: name.contains) else { return 0 }
        if blsWholeGrainWords.contains(where: name.contains) { return 1 }
        // The grains that are whole as they are sold, but only in the BLS's grain group: a gluten-free millet
        // bread is made from milled flour and says nothing about whole grain.
        let letter = id.dropFirst(4).first.map { String($0).lowercased() }
        return letter == "c" && wholeByNatureWords.contains(where: name.contains) ? 1 : 0
    }

    /// How much of a food's sugar is free sugar: what the coach or the wearer worked out, else none, except a
    /// sweetened drink, whose sugar is free sugar by definition. Milk and whole fruit carry their sugar inside
    /// the food, so an unclassified food is not charged for it.
    static func freeSugarShare(_ entry: FoodLogEntry, facts: FoodFacts?, groups: [(Group, Double)]) -> Double {
        if let share = facts?.freeSugarShare { return share.clamped(0, 1) }
        let isDrink = groups.contains { $0.0 == .drink && $0.1 > 0 }
        guard isDrink, let per100 = entry.per100g?["sugar_g"], per100 >= 2.5 else { return 0 }
        return 1
    }

    /// Which groups a food's weight falls into: the classification when there is one, else the single group the
    /// log can place it in, else nothing, which costs the score nothing.
    static func groups(of entry: FoodLogEntry, facts: [String: FoodFacts]) -> [(Group, Double)] {
        let info = entry.foodId.flatMap { facts[$0] }
        if let shares = info?.shares, !shares.isEmpty {
            return shares.compactMap { group, share in share > 0 ? (group, share.clamped(0, 1)) : nil }
        }
        guard let group = kind(of: entry, group: info?.group, name: entry.name.lowercased()) else { return [] }
        return [(group, 1)]
    }

    /// Sausage, ham, bacon and other cured or smoked meat, by name, for foods whose source does not say it.
    static let processedMeatWords = ["wurst", "salami", "schinken", "speck", "bacon", "sausage", "chorizo",
                                     "leberkäse", "pastrami", "mortadella", "kassler", "frankfurter", "wiener"]

    static let wholeGrainWords = ["vollkorn", "whole grain", "wholegrain", "whole wheat", "wholemeal"]
    /// What the BLS calls whole grain, in German and in English: the word itself, the whole kernel, flakes
    /// (rolled whole grain), unpolished rice, wild rice and groats (cracked whole grain).
    static let blsWholeGrainWords = wholeGrainWords + ["ganzes korn", "flocken", "flakes", "unpoliert",
                                                        "brown rice", "wildreis", "wild rice", "grütze", "groats"]
    /// Pseudo-cereals, whole as they are sold.
    static let wholeByNatureWords = ["quinoa", "amaranth", "buchweizen", "buckwheat", "hirse", "millet", "grünkern"]
    /// Parts of a grain rather than the whole grain: bran, germ and semolina.
    static let grainFractionWords = ["kleie", "bran", "keim", "germ", "grieß", "semolina", "stärke", "starch"]
    static let juiceWords = ["saft", "juice", "nektar", "nectar", "smoothie"]
    static let nutWords = ["nuss", "nüsse", "mandel", "nut", "almond", "kern", "seed", "samen", "pistazie", "pistachio"]

    /// Which group a food falls in: BLS letters first (potatoes are not vegetables, juice is a drink and
    /// not fruit, poultry is not red meat), then the Open Food Facts group, then words in the name.
    static func kind(of entry: FoodLogEntry, group: String?, name: String) -> Group? {
        if let id = entry.foodId, id.hasPrefix("bls:"), let letter = id.dropFirst(4).first.map({ String($0).lowercased() }) {
            switch letter {
            // BLS G is vegetables, K mushrooms, which the parts count with them.
            case "g", "k": return .vegetables
            case "f": return juiceWords.contains(where: name.contains) ? .drink : .fruit
            case "h": return nutWords.contains(where: name.contains) ? .nuts : .legumes
            // BLS W is sausage and cured meat, processed whatever the animal; U is meat as such.
            case "w": return .processedMeat
            case "u":
                if poultryWords.contains(where: name.contains) { return nil }
                return processedMeatWords.contains(where: name.contains) ? .processedMeat : .redMeat
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
        if raw.contains("processed-meat") || raw.contains("sausages") { return .processedMeat }
        if raw.contains("meat") && !poultryWords.contains(where: name.contains) {
            return processedMeatWords.contains(where: name.contains) ? .processedMeat : .redMeat
        }
        return nil
    }

    static let poultryWords = ["huhn", "hähnchen", "hühn", "pute", "truthahn", "geflügel", "ente", "gans", "chicken", "turkey", "poultry", "duck"]
}
