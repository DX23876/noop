import Foundation
import WhoopStore

/// What a food is made of, beyond what its label states (owner, 2026-11-22). Open Food Facts carries one coarse
/// category and leaves many products without any, so the nutrition score could not see oats as whole grain, chia
/// as seeds or a granola as both. The coach works this out once per product from its name, category, ingredient
/// list and nutrients; the wearer can correct it, and a correction is never overwritten.
///
/// Stored as JSON on the wearer's own food (`CustomFood.classification`), so the store keeps it without reading
/// it and both platforms read the same shape.
public struct FoodClassification: Equatable, Sendable, Codable {
    /// Who said so. The wearer's own answer stands above the coach's and is never replaced by it.
    public enum Author: String, Sendable, Codable { case coach, wearer }

    /// At most this many groups per food: a food that needs a fourth share is a recipe, not a product.
    public static let maximumShares = 3
    /// The rules this classification was made under. A later version does not reclassify by itself; the wearer
    /// asks for it (owner, 2026-11-22).
    public static let currentVersion = 1

    /// The groups the food's weight falls into, keyed by `FoodScore.Group`'s raw value, each 0 to 1.
    public var shares: [String: Double]
    /// How much of the food's weight is whole-grain cereal, 0 to 1. Nil when the product does not let anyone
    /// tell: the name and category rules then answer, instead of a zero nobody said.
    public var wholeGrainShare: Double?
    /// How much of the food's sugar is free sugar as the WHO means it (added sugar, honey, syrup, juice sugar,
    /// never the sugar inside milk or whole fruit), 0 to 1. Nil when it cannot be told; the drink rule answers.
    public var freeSugarShare: Double?
    /// How processed the food is, as NOVA counts it (1 unprocessed, 2 a culinary ingredient, 3 processed, 4 ultra-
    /// processed), judged from the ingredient list. Open Food Facts works its class out by rule from single
    /// ingredient markers, and called a protein bread and seasoned chicken strips ultra-processed beside products
    /// that are (owner, 2026-11-28). Nil when the product does not let anyone tell; the label's class then stands.
    public var processing: Int?
    public var author: Author
    public var version: Int

    public init(shares: [FoodScore.Group: Double] = [:], wholeGrainShare: Double? = nil, freeSugarShare: Double? = nil,
                processing: Int? = nil, author: Author = .coach, version: Int = FoodClassification.currentVersion) {
        self.shares = Dictionary(uniqueKeysWithValues: shares.map { ($0.key.rawValue, $0.value) })
        self.wholeGrainShare = wholeGrainShare
        self.freeSugarShare = freeSugarShare
        self.processing = processing
        self.author = author
        self.version = version
    }

    /// The shares as groups, with anything unknown, negative or beyond the whole dropped.
    public var groupShares: [FoodScore.Group: Double] {
        var out: [FoodScore.Group: Double] = [:]
        for (raw, share) in shares.sorted(by: { $0.value > $1.value }) {
            guard out.count < Self.maximumShares, let group = FoodScore.Group(rawValue: raw),
                  share.isFinite, share > 0 else { continue }
            out[group] = min(1, share)
        }
        return out
    }

    /// What the score reads, with the stored group the entry already had. The processing class judged here
    /// stands above the label's, which Open Food Facts derives by rule.
    public func facts(group: String?, nova: Int?) -> FoodScore.FoodFacts {
        FoodScore.FoodFacts(group: group, nova: processing ?? nova, shares: groupShares.isEmpty ? nil : groupShares,
                            wholeGrainShare: wholeGrainShare.map { $0.clamped(0, 1) },
                            freeSugarShare: freeSugarShare.map { $0.clamped(0, 1) }, classified: true)
    }

    /// Nothing is made of more than itself: the shares together may not pass the whole food, and every share is
    /// a share. A classification that fails this is not stored.
    public var isSound: Bool {
        let values = shares.values
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), values.reduce(0, +) <= 1.0001,
              shares.count <= Self.maximumShares, shares.keys.allSatisfy({ FoodScore.Group(rawValue: $0) != nil }),
              wholeGrainShare.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              freeSugarShare.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              processing.map({ (1...4).contains($0) }) ?? true else { return false }
        return true
    }

    public var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String?) -> FoodClassification? {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(FoodClassification.self, from: data) else { return nil }
        return value.isSound ? value : nil
    }
}

/// The salt a wearer loses through sweat, as an allowance on the score's salt limit (owner, 2026-11-22).
///
/// Sweat carries roughly 0.5 to 2 g of sodium per litre, so a hard hour can cost a gram, which the fixed limits
/// know nothing about. The signal is the burn the strap measured above the wearer's usual day: it is already
/// resolved for the calorie goal, it covers work the wearer never logged as a session, and it needs no second
/// idea of what a training day is.
///
/// It deliberately does NOT read `DietActiveDay.bonusKcal`. That value is a calorie-budget decision: it is zero
/// unless the wearer switched active days on, zero on a plan's own training days, and zero while fasting. Salt
/// lost through sweat does not care about any of that, and reusing the bonus would have left this allowance at
/// zero for a wearer whose plan has active days off.
public enum FoodSweat {
    /// Sodium allowed per extra kilocalorie burned. A litre of sweat is lost around 600 to 800 kcal of sustained
    /// work and carries about a gram of sodium; 1.5 mg per kcal sits at the cautious end of that.
    public static let perExtraKcalMg = 1.5
    /// Never more than this, whatever the day looked like: beyond it the limits would stop saying anything.
    public static let maximumMg = 900.0
    /// Below this the allowance is not worth showing.
    public static let shownFromMg = 50.0

    /// The allowance for a day. `burnedKcal` is what the strap and Health measured that day so far,
    /// `usualBurnKcal` the wearer's usual burn for a whole day, `elapsedFraction` how much of the day has passed
    /// (1 for a past day), so today's part-day burn is held against today's part-day usual.
    public static func allowanceMg(burnedKcal: Double?, usualBurnKcal: Double?, elapsedFraction: Double = 1)
        -> Double {
        guard let burned = burnedKcal, let usual = usualBurnKcal, burned.isFinite, usual.isFinite, usual > 0
        else { return 0 }
        let usualSoFar = usual * elapsedFraction.clamped(0, 1)
        let extra = max(0, burned - usualSoFar)
        return min(maximumMg, (extra * perExtraKcalMg / 50).rounded() * 50)
    }
}

extension FoodItem {
    /// What the nutrition score should know about this food: its classification when it has one, else the
    /// category and processing class it came with. The one place a food becomes facts, so no screen, report or
    /// coach tool can read it differently.
    public var scoreFacts: FoodScore.FoodFacts {
        classification?.facts(group: group, nova: nova) ?? FoodScore.FoodFacts(group: group, nova: nova)
    }
}
