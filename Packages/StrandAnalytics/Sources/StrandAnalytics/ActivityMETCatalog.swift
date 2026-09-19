import Foundation

// ActivityMETCatalog.swift — what a session COSTS when nothing recorded what it cost.
//
// Pure, DB-free, no clock. It answers one question: given a sport name and a duration, roughly how
// much energy did that session take? It exists because a real gap has a real consequence — a Hevy
// strength session and an imported lift log both arrive with `energyKcal == nil`, and a day whose
// only activity is such a session used to contribute nothing at all to the energy total.
//
// Three boundaries keep this honest:
//
//   • It is a LAST resort. `EnergyEngine` and its callers reach for a recorded figure first, then a
//     heart-rate estimate, and only then this table. A MET value is a population average for an
//     activity NAME; heart rate is evidence about the person who did it.
//   • Its output is marked as estimated all the way to the screen (`ActivityContribution.isEstimated`).
//     A table lookup must never arrive looking like a measurement.
//   • A MET is a GROSS multiple of resting metabolism, so the figure it produces still contains the
//     bout's resting energy. It is therefore handed over as a gross quantity and converted exactly
//     once, in `EnergyEngine`, like every other gross source.
//
// Values are the published activity costs from the Compendium of Physical Activities (Ainsworth et
// al.; 2024 Adult Compendium), rounded to the table's own precision and picked at the GENERAL entry
// for each sport rather than a competitive one — the person logging "Tennis" is far more often
// playing than competing, and the general entry is the conservative read.
public enum ActivityMETCatalog {

    /// What an unrecognised sport costs. Deliberately low: 3.5 MET is brisk-walking effort, which is
    /// roughly the least a person is doing when they bother to log a session at all, and underpaying
    /// an unknown activity is the error this file would rather make.
    public static let defaultMET = 3.5

    /// Gross energy for a session of `sport` lasting `seconds`, in kcal, or nil without a body mass.
    ///
    /// 1 MET is 1 kcal per kg of body mass per hour by definition, which is the whole of the
    /// arithmetic here — the judgement all sits in the table.
    public static func grossKcal(sport: String, seconds: Double, weightKg: Double) -> Double? {
        guard seconds > 0, seconds.isFinite, weightKg > 0, weightKg.isFinite else { return nil }
        return met(forSport: sport) * weightKg * (seconds / 3_600)
    }

    /// The MET value for a sport label, or `defaultMET` for anything the table does not name.
    ///
    /// Matching normalises the way the app's own `WorkoutSource.sportKey` does (lowercased, spaces
    /// removed) and then, on a miss, once more without punctuation — so "Open-water swim",
    /// "open water swim" and "Openwater Swim" are the same activity rather than three, and a free-text
    /// sport (the picker is a suggestion set, not a whitelist) still has a chance of landing.
    public static func met(forSport sport: String) -> Double {
        let key = normalized(sport)
        if let hit = table[key] { return hit }
        let plain = key.filter { $0.isLetter || $0.isNumber }
        return table[plain] ?? defaultMET
    }

    private static func normalized(_ sport: String) -> String {
        sport.lowercased().filter { !$0.isWhitespace }
    }

    /// Keys are `normalized(...)` spellings of `WorkoutCatalog.all`, which is the set of sports the app
    /// itself offers. A broader port would be hundreds of rows for activities that never reach it.
    private static let table: [String: Double] = [
        // Foot
        "running": 8.3, "treadmillrun": 8.3, "walking": 3.5, "treadmillwalk": 3.5,
        "nordicwalking": 4.8, "hiking": 6.0, "rucking": 7.0, "snowshoeing": 7.5,
        "stairclimber": 9.0, "jumprope": 12.3, "parkour": 8.0,
        // Wheels and water
        "cycling": 7.5, "indoorcycle": 7.0, "spinning": 8.5, "mountainbiking": 8.5,
        "openwaterswim": 7.0, "poolswim": 6.0, "rowing": 7.0, "rowmachine": 7.0,
        "kayaking": 5.0, "sailing": 3.0, "standuppaddleboard": 6.0, "surfing": 3.0,
        "scubadiving": 7.0, "waterpolo": 10.0, "kiteboarding": 6.0, "fishing": 3.5,
        // Gym
        "elliptical": 5.0, "hiit": 8.0, "crossfit": 8.0, "bootcamp": 8.0, "calisthenics": 6.0,
        "strength": 5.0, "bodybuilding": 5.0, "weightlifting": 5.0, "powerlifting": 6.0,
        "gymnastics": 3.8, "climbing": 7.5,
        // Low intensity
        "yoga": 2.5, "pilates": 3.0, "stretching": 2.3, "meditation": 1.3, "gaming": 1.5,
        "darts": 2.5, "billiards": 2.5, "bowling": 3.0, "golf": 4.8, "discgolf": 3.0,
        "archery": 3.5, "curling": 4.0, "hunting": 5.0, "skydiving": 3.5, "motorracing": 3.0,
        "motocross": 4.0, "wheelchair": 4.0, "horsebackriding": 5.5,
        // Combat
        "boxing": 7.8, "kickboxing": 10.3, "martialarts": 10.3, "jiujitsu": 10.3, "judo": 10.3,
        "muaythai": 10.3, "fencing": 6.0, "paintball": 6.0,
        // Ball and court
        "basketball": 6.5, "soccer": 7.0, "baseball": 5.0, "softball": 5.0, "volleyball": 4.0,
        "sandvolleyball": 8.0, "badminton": 5.5, "tennis": 7.3, "squash": 7.3, "racquetball": 7.0,
        "tabletennis": 4.0, "handball": 12.0, "netball": 6.0, "pickleball": 4.5, "padel": 6.0,
        "spikeball": 6.0, "frisbee": 3.0, "polo": 8.0,
        // Field
        "icehockey": 8.0, "fieldhockey": 7.8, "lacrosse": 8.0, "rugby": 8.3,
        "americanfootball": 8.0, "australianfootball": 8.0, "gaelicfootball": 8.0,
        "cricket": 4.8, "hurling/camogie": 8.0, "hurlingcamogie": 8.0,
        // Ice, snow, board
        "skiing": 7.0, "snowboarding": 5.3, "iceskating": 7.0, "inlineskating": 7.5,
        "skateboarding": 5.0,
        // Movement to music
        "dancing": 5.0, "ballet": 5.0, "breakdancing": 7.3, "cheerleading": 6.0,
    ]
}
