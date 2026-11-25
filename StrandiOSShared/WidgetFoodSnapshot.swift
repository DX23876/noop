import Foundation

/// Today's eating for the Nutrition widget (owner, 2026-11-25): what was eaten, the day's goal and the three
/// macronutrients. The app writes it whenever the Food page or the Today tile reads today; the widget only reads.
/// Kept under its own App Group key, apart from `WidgetSnapshot`, so the food page can publish without the score
/// publisher and neither can overwrite the other's fields.
public struct WidgetFoodSnapshot: Codable, Equatable {
    public var day: String
    public var eatenKcal: Int
    public var goalKcal: Int?
    public var proteinG: Int
    public var carbsG: Int
    public var fatG: Int
    public var proteinGoal: Int?
    public var carbsGoal: Int?
    public var fatGoal: Int?

    public init(day: String, eatenKcal: Int, goalKcal: Int?, proteinG: Int, carbsG: Int, fatG: Int,
                proteinGoal: Int?, carbsGoal: Int?, fatGoal: Int?) {
        self.day = day; self.eatenKcal = eatenKcal; self.goalKcal = goalKcal
        self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        self.proteinGoal = proteinGoal; self.carbsGoal = carbsGoal; self.fatGoal = fatGoal
    }

    public static let storageKey = "noop.widget.food"
    public static let widgetKind = "NOOPFoodWidget"

    /// What is left of today's goal, never below nothing.
    public var leftKcal: Int? { goalKcal.map { max(0, $0 - eatenKcal) } }

    /// The snapshot to draw at `now`: yesterday's is no answer for today, so it reads as nothing eaten yet.
    public static func load(now: Date = Date()) -> WidgetFoodSnapshot? {
        guard let data = UserDefaults(suiteName: WidgetSnapshot.suiteName)?.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(WidgetFoodSnapshot.self, from: data),
              snapshot.day == WidgetSnapshot.localDayKey(now) else { return nil }
        return snapshot
    }

    /// Writes the snapshot when it differs from the stored one. True when it wrote, so the caller asks WidgetKit
    /// for a new timeline only then.
    @discardableResult
    public func save() -> Bool {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return false }
        if let data = defaults.data(forKey: Self.storageKey),
           (try? JSONDecoder().decode(WidgetFoodSnapshot.self, from: data)) == self { return false }
        guard let encoded = try? JSONEncoder().encode(self) else { return false }
        defaults.set(encoded, forKey: Self.storageKey)
        return true
    }
}
