import Foundation

/// Where more protein comes from (owner, 2026-11-10), for the protein suggestion's page on iOS and Android: the food
/// groups richest in protein with an everyday portion's protein, rounded from ordinary food tables, without the
/// groups the plan's addon leaves out (vegetarian, vegan).
public enum DietProteinSources {
    public static let all: [(group: FoodGroupMotif, grams: Int)] = [
        (.poultry, 35), (.meat, 32), (.fish, 30), (.dairy, 25), (.legumes, 18), (.eggs, 13),
    ]

    /// The protein a listed portion brings, about.
    public static let portionGrams: Double = 30

    public static func groups(addon: DietAddon?) -> [(group: FoodGroupMotif, grams: Int)] {
        all.filter { !(addon?.leavesOut.contains($0.group) ?? false) }
    }

    /// How many more portions a day close the gap between last week's mean and the goal; 0 when nothing is short.
    public static func portionsToClose(goalG: Double, meanG: Double) -> Int {
        Int((max(0, goalG - meanG) / portionGrams).rounded(.up))
    }
}
