#if os(iOS)
import SwiftUI
import StrandCore

/// The planner's words and pictures in one place: plain language, no method names, study findings told in everyday
/// words with their sources behind the info button.
enum DietText {
    // MARK: Goals and paces

    static func goal(_ g: DietPlan.Goal) -> String {
        switch g {
        case .lose: String(localized: "Lose weight")
        case .maintain: String(localized: "Hold my weight")
        case .gain: String(localized: "Build muscle")
        }
    }

    static func goalDetail(_ g: DietPlan.Goal) -> String {
        switch g {
        case .lose: String(localized: "A steady deficit you can keep, with enough protein to protect your muscles.")
        case .maintain: String(localized: "Eat as much as you burn and eat better along the way.")
        case .gain: String(localized: "A small surplus and plenty of protein, so the gain is mostly muscle.")
        }
    }

    static func pace(_ p: DietPlan.Pace) -> String {
        switch p {
        case .gentle: String(localized: "Gentle")
        case .normal: String(localized: "Normal")
        case .ambitious: String(localized: "Ambitious")
        }
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(AppLanguage.activeLocale)) + " %"
    }

    static func kg(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(AppLanguage.activeLocale)) + " kg"
    }

    // MARK: Forms

    static func form(_ f: DietForm) -> String {
        switch f {
        case .balanced: String(localized: "Balanced")
        case .mediterranean: String(localized: "Mediterranean")
        case .dash: String(localized: "Heart healthy (DASH)")
        case .highProtein: String(localized: "High protein")
        case .flexitarian: String(localized: "Flexitarian")
        case .lowFat: String(localized: "Low fat")
        case .lowCarb: String(localized: "Low carb")
        case .keto: String(localized: "Keto")
        case .fasting168: String(localized: "Fasting 16:8")
        case .fasting52: String(localized: "Fasting 5:2")
        case .alternateDay: String(localized: "Alternate day fasting")
        case .alternateDayFull: String(localized: "Alternate day fasting, full")
        }
    }

    static func formWhy(_ f: DietForm) -> String {
        switch f {
        case .balanced: String(localized: "Nothing is left out. The easiest start.")
        case .mediterranean: String(localized: "Vegetables, fish, pulses and olive oil. The way of eating with the best record for long-term health.")
        case .dash: String(localized: "Lots of vegetables, fruit and low fat dairy, little salt. Made for blood pressure.")
        case .highProtein: String(localized: "Keeps you full and protects your muscles in a deficit.")
        case .flexitarian: String(localized: "Mostly plants, meat or fish now and then.")
        case .lowFat: String(localized: "Big portions for few calories.")
        case .lowCarb: String(localized: "Less bread, pasta and rice. Some feel fewer cravings.")
        case .keto: String(localized: "Almost no carbohydrate. For people who find strict rules easier than moderation.")
        case .fasting168: String(localized: "Eat within eight hours, nothing in the other sixteen.")
        case .fasting52: String(localized: "Two days a week at about a quarter of your usual food, five ordinary days.")
        case .alternateDay: String(localized: "Every other day at about a quarter of your usual food.")
        case .alternateDayFull: String(localized: "Every other day without food. Only with a doctor's okay.")
        }
    }

    static func formWatch(_ f: DietForm) -> String? {
        switch f {
        case .mediterranean: String(localized: "Oil and nuts are rich in calories.")
        case .highProtein: String(localized: "Takes a little more planning when shopping.")
        case .lowFat: String(localized: "Keep fish and some oil, your body needs those fats.")
        case .lowCarb: String(localized: "Bread, pasta and rice become rare.")
        case .keto: String(localized: "Tired first weeks, hard with friends, little fibre. Talk to a doctor first.")
        case .fasting168: String(localized: "No advantage at the same calories, the first weeks feel long.")
        case .fasting52, .alternateDay: String(localized: "Fasting days are hard at first. Plan them on quiet days.")
        case .alternateDayFull: String(localized: "Whole days without food are not for everyone, and not for people with diabetes or an eating disorder.")
        default: nil
        }
    }

    static func addon(_ a: DietAddon?) -> String {
        switch a {
        case nil: String(localized: "Everything")
        case .pescatarian?: String(localized: "Pescatarian")
        case .vegetarian?: String(localized: "Vegetarian")
        case .vegan?: String(localized: "Vegan")
        }
    }

    static func addonDetail(_ a: DietAddon?) -> String {
        switch a {
        case nil: String(localized: "Meat, fish and plants.")
        case .pescatarian?: String(localized: "Fish, no meat.")
        case .vegetarian?: String(localized: "No meat or fish. Plan protein on purpose.")
        case .vegan?: String(localized: "Nothing from animals. Plan protein and take B12.")
        }
    }

    static func keep(_ k: DietPlan.Keep) -> String {
        switch k {
        case .breadAndPasta: String(localized: "Bread and pasta")
        case .meat: String(localized: "Meat")
        case .sweets: String(localized: "Something sweet")
        case .lateEating: String(localized: "Late dinners")
        case .regularMeals: String(localized: "Three meals a day")
        }
    }

    static func reason(_ r: DietSuggest.Reason) -> String {
        switch r {
        case .closestToYourLog: String(localized: "Closest to how you eat now")
        case .keepsWhatYouLove: String(localized: "Keeps what you love")
        case .likesRules: String(localized: "Clear rules")
        case .strength: String(localized: "Good with strength training")
        case .easyStart: String(localized: "Easy to start")
        }
    }

    // MARK: Effort and notes

    static func effort(_ e: DietTargets.Effort) -> String {
        switch e {
        case .easy: String(localized: "Easy to live with")
        case .doable: String(localized: "Doable")
        case .demanding: String(localized: "Demanding")
        case .veryHard: String(localized: "Very hard")
        }
    }

    static func effortTint(_ score: Double) -> Color {
        score < 2 ? ForgeColor.nutrientLeaf : score < 3 ? ForgeColor.carbs : score < 4.5 ? ForgeColor.nutrientSun : ForgeColor.nutrientRed
    }

    static func note(_ n: DietTargets.Note) -> String {
        switch n {
        case .paceCapped: String(localized: "The pace was set to the highest this mode allows.")
        case .paceAboveRecommended: String(localized: "Faster than 1 % a week costs muscle and makes you hungrier. Allowed, but not what Forge suggests.")
        case .floorApplied: String(localized: "Your week stays at 1,200 kcal a day on average at the least. Forge does not plan crash diets.")
        case .proteinLow: String(localized: "Protein is below what your goal needs. Your muscles may pay for it.")
        case .youngNoDeficit: String(localized: "Under 18, Forge plans to hold your weight and eat well, not a deficit.")
        case .pregnancyNoDeficit: String(localized: "During pregnancy and nursing, Forge plans no deficit. Your doctor knows best.")
        case .underweightNoDeficit: String(localized: "Your weight is already low. Forge plans to hold it, not to lose more.")
        case .goalWeightRaised: String(localized: "The goal weight was raised to the lowest healthy weight for your height.")
        }
    }

    static func hold(_ h: DietAdjust.Hold) -> String {
        switch h {
        case .manualSteering: String(localized: "You set the calories yourself, so Forge does not change them.")
        case .tooEarly: String(localized: "The first two weeks move with water weight. Forge looks again after that.")
        case .notAWeekYet: String(localized: "Forge checks once a week.")
        case .fewLoggedDays: String(localized: "Too few logged days this week to judge. Forge keeps your goal.")
        case .fewWeighIns: String(localized: "Too few weigh-ins this week to see a trend. Forge keeps your goal.")
        case .onPlan: String(localized: "Your weight follows the plan. Nothing to change.")
        }
    }

    // MARK: Explainer cards

    static let explainStartTitle = String(localized: "Before we plan")
    static let explainStart = String(localized: "Most diets do not fail at losing weight, they fail afterwards. In large reviews, more than half of the weight lost comes back within two years, and often most of it within five. The reason is rarely a lack of will: the body pushes back. After losing weight you get noticeably hungrier and burn a little less. Staying lighter needs habits you will still live in a year, not a short hard diet. So Forge plans with you slowly and honestly.")
    static let explainPaceTitle = String(localized: "Why not faster?")
    static let explainPace = String(localized: "Losing fast feels good, but it often costs muscle and makes you hungrier. Up to about 1 % of your weight a week stays doable, above all with enough protein and some strength training. Slower is not worse: it is the pace you keep up for longer.")
    static let explainHoldTitle = String(localized: "After the goal comes holding")
    static let explainHold = String(localized: "People who keep their weight for years often share the same habits: they weigh themselves regularly, move a lot, eat similarly across the week and notice setbacks early. Forge helps: it shows your trend every week, and when you reach your goal it plans the step to holding instead of simply lifting the calories.")
    static let explainFormsTitle = String(localized: "Which way of eating works best?")
    static let explainForms = String(localized: "At the same calories and enough protein, people lose about the same on all of them. What counts is whether you keep it up. Pick the one that suits your life, not the one that sounds strictest.")
    static let sources = String(localized: "Sources: a review of 29 long-term studies of weight loss (Anderson and others, 2001), a review of keeping lost weight off (Hall and Kahan, 2018), and the US National Weight Control Registry of people who kept their weight off.")
}

/// The planner's pictures. Its own series where it exists, else the closest meal still life, so a missing picture
/// never leaves a hole.
enum DietArt {
    static func goal(_ g: DietPlan.Goal) -> String {
        named("dietGoal_\(g.rawValue)", fallback: g == .gain ? "foodMotif_poultry" : g == .lose ? "foodMotif_vegetables" : "foodScoreHero")
    }

    static func form(_ f: DietForm) -> String {
        let fallback: String
        switch f {
        case .balanced, .flexitarian: fallback = "foodMotif_dishes"
        case .mediterranean: fallback = "foodMotif_fats"
        case .dash: fallback = "foodMotif_vegetables"
        case .highProtein: fallback = "foodMotif_eggs"
        case .lowFat: fallback = "foodMotif_fruit"
        case .lowCarb, .keto: fallback = "foodMotif_meat"
        case .fasting168, .fasting52, .alternateDay, .alternateDayFull: fallback = "foodMotif_drinks"
        }
        let key: String
        switch f {
        case .fasting168, .fasting52, .alternateDay, .alternateDayFull: key = "dietForm_fasting"
        default: key = "dietForm_\(f.rawValue)"
        }
        return named(key, fallback: fallback)
    }

    static func addon(_ a: DietAddon?) -> String {
        guard let a else { return named("dietForm_balanced", fallback: "foodMotif_dishes") }
        return named("dietForm_\(a.rawValue)", fallback: a == .pescatarian ? "foodMotif_fish" : "foodMotif_legumes")
    }

    static func explain(_ name: String) -> String { named("dietExplain_\(name)", fallback: "foodScoreHero") }

    private static func named(_ name: String, fallback: String) -> String {
        UIImage(named: name) == nil ? fallback : name
    }
}
#endif
