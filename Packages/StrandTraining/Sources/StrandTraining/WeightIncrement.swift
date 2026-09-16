import Foundation

/// The smallest sensible change in total load for one set. A barbell is loaded symmetrically, so its
/// step is two of the smallest available plates; other equipment uses the wearer's configured step.
public enum WeightIncrement {
    public static let barbellEquipmentIds: Set<String> = ["barbell", "ez-bar", "trap-bar", "smith-machine"]
    public static let minimumStepKg = 0.25

    public static func step(equipmentIds: [String], platePairsKg: [Double], fallbackKg: Double) -> Double {
        let fallback = max(minimumStepKg, fallbackKg)
        guard !barbellEquipmentIds.isDisjoint(with: equipmentIds),
              let smallest = platePairsKg.filter({ $0 > 0 }).min() else { return fallback }
        return smallest * 2
    }
}
