import Foundation
import StrandCore

/// `workout.sportName`: a sport in the wearer's language for Android, from the same catalogue keys the iPhone's
/// `WorkoutSource.localizedDisplaySport` (`Strand/Data/WorkoutSource.swift`) uses, so a strength session reads
/// "Krafttraining" on both phones. Android showed every sport in English (found 2026-11-28). The two tables must
/// list the same cases; `Tools/test_sport_name_twins.py` holds them together.
enum CoreSportName {
    /// The lowercased display name of each sport the iPhone translates by a key of its own, and that key.
    static let keys: [String: String] = [
        "running": "sport.running",
        "walking": "Walking",
        "hiking": "Hiking",
        "cycling": "Cycling",
        "open-water swim": "Open-water swim",
        "rowing": "Rowing",
        "treadmill run": "Treadmill run",
        "treadmill walk": "Treadmill walk",
        "indoor cycle": "Indoor cycle",
        "pool swim": "Pool swim",
        "row machine": "Row machine",
        "elliptical": "Elliptical",
        "hiit": "HIIT",
        "yoga": "Yoga",
        "functional strength training": "Functional strength training",
        "strength training": "Strength Training",
        "strength": "Strength",
    ]

    /// The sport as the wearer reads it. Unknown and user-typed names pass through, as on the iPhone; English, which
    /// ships no table, reads each key's own English.
    static func name(_ sport: String) -> String {
        if sport == "detected" { return CoreLocalization.lookup("Activity") ?? "Activity" }
        let display = WorkoutSource.splitCamelCase(sport)
        let lower = display.lowercased()
        if let key = keys[lower] {
            return CoreLocalization.lookup(key) ?? (key == "sport.running" ? "Running" : key)
        }
        return CoreLocalization.lookup("sport." + lower) ?? display
    }
}
