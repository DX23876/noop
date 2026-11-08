#if os(iOS)
import Foundation
import HealthKit
import StrandCore
import WhoopStore

/// Writes the food log to Apple Health (decision 2026-11-08): one food correlation per entry, holding every
/// nutrient Health has a type for, and removes it again when the entry is deleted or replaced. The nutrition
/// import skips samples NOOP wrote itself (`source != HKSource.default()` in `HealthKitBridge`), so a logged
/// meal is never counted twice.
enum FoodHealthSync {
    /// On by default once the wearer allowed Health; Settings › Food can turn it off.
    static let enabledKey = "food.health.write.enabled"

    private static let store = HKHealthStore()

    /// Canonical nutrient -> Health type and unit. Water, alcohol, salt and the omega-3 split have no type
    /// of their own, or one another screen already owns (water), so they stay in NOOP.
    static let types: [(FoodNutrient, HKQuantityTypeIdentifier, HKUnit)] = [
        (.energyKcal, .dietaryEnergyConsumed, .kilocalorie()), (.proteinG, .dietaryProtein, .gram()),
        (.carbsG, .dietaryCarbohydrates, .gram()), (.fatG, .dietaryFatTotal, .gram()), (.fiberG, .dietaryFiber, .gram()),
        (.sugarG, .dietarySugar, .gram()), (.satFatG, .dietaryFatSaturated, .gram()),
        (.monoFatG, .dietaryFatMonounsaturated, .gram()), (.polyFatG, .dietaryFatPolyunsaturated, .gram()),
        (.cholesterolMg, .dietaryCholesterol, .gramUnit(with: .milli)), (.sodiumMg, .dietarySodium, .gramUnit(with: .milli)),
        (.potassiumMg, .dietaryPotassium, .gramUnit(with: .milli)), (.calciumMg, .dietaryCalcium, .gramUnit(with: .milli)),
        (.magnesiumMg, .dietaryMagnesium, .gramUnit(with: .milli)), (.phosphorusMg, .dietaryPhosphorus, .gramUnit(with: .milli)),
        (.ironMg, .dietaryIron, .gramUnit(with: .milli)), (.zincMg, .dietaryZinc, .gramUnit(with: .milli)),
        (.iodineUg, .dietaryIodine, .gramUnit(with: .micro)), (.copperMg, .dietaryCopper, .gramUnit(with: .milli)),
        (.manganeseMg, .dietaryManganese, .gramUnit(with: .milli)), (.vitaminAUg, .dietaryVitaminA, .gramUnit(with: .micro)),
        (.vitaminDUg, .dietaryVitaminD, .gramUnit(with: .micro)), (.vitaminEMg, .dietaryVitaminE, .gramUnit(with: .milli)),
        (.vitaminKUg, .dietaryVitaminK, .gramUnit(with: .micro)), (.thiaminMg, .dietaryThiamin, .gramUnit(with: .milli)),
        (.riboflavinMg, .dietaryRiboflavin, .gramUnit(with: .milli)), (.niacinMg, .dietaryNiacin, .gramUnit(with: .milli)),
        (.vitaminB6Mg, .dietaryVitaminB6, .gramUnit(with: .milli)), (.folateUg, .dietaryFolate, .gramUnit(with: .micro)),
        (.vitaminB12Ug, .dietaryVitaminB12, .gramUnit(with: .micro)), (.vitaminCMg, .dietaryVitaminC, .gramUnit(with: .milli)),
        (.pantothenicMg, .dietaryPantothenicAcid, .gramUnit(with: .milli)), (.biotinUg, .dietaryBiotin, .gramUnit(with: .micro)),
    ]

    /// The share types `HealthKitBridge` adds to its permission request.
    static var writeIds: [HKQuantityTypeIdentifier] { types.map(\.1) }

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Writes new entries and stores the record id on each.
    static func wrote(_ entries: [FoodLogEntry], store db: WhoopStore) async {
        guard enabled, HKHealthStore.isHealthDataAvailable() else { return }
        for entry in entries {
            guard let correlation = correlation(for: entry) else { continue }
            do {
                try await store.save(correlation)
                try? await db.setFoodLogHealthId(entryId: entry.id, healthId: correlation.uuid.uuidString)
            } catch {
                // Not allowed or not available: the entry stays in NOOP; nothing to undo.
            }
        }
    }

    /// An edited entry: the old record goes, the new one is written.
    static func replaced(old: FoodLogEntry, new: FoodLogEntry, store db: WhoopStore) async {
        await removed([old])
        var fresh = new
        fresh.healthId = nil
        await wrote([fresh], store: db)
    }

    /// Deletes the records of removed entries, the food correlation and the samples inside it.
    static func removed(_ entries: [FoodLogEntry]) async {
        let ids = entries.compactMap { $0.healthId.flatMap(UUID.init(uuidString:)) }
        guard !ids.isEmpty, let type = HKObjectType.correlationType(forIdentifier: .food) else { return }
        let predicate = HKQuery.predicateForObjects(with: Set(ids))
        let found: [HKSample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, _ in continuation.resume(returning: samples ?? []) }
            store.execute(query)
        }
        var objects: [HKObject] = []
        for case let correlation as HKCorrelation in found {
            objects.append(correlation)
            objects.append(contentsOf: correlation.objects)
        }
        guard !objects.isEmpty else { return }
        try? await store.delete(objects)
    }

    static func correlation(for entry: FoodLogEntry) -> HKCorrelation? {
        guard let type = HKObjectType.correlationType(forIdentifier: .food) else { return nil }
        let at = Date(timeIntervalSince1970: TimeInterval(entry.loggedAt))
        let amounts = NutrientAmounts(stored: entry.totals)
        let metadata: [String: Any] = [HKMetadataKeyFoodType: entry.name,
                                       HKMetadataKeyExternalUUID: "noop:food:\(entry.id)",
                                       "com.noop.health.origin": "noop"]
        var samples = Set<HKSample>()
        for (nutrient, id, unit) in types {
            guard let value = amounts[nutrient], value > 0 || nutrient == .energyKcal,
                  let quantityType = HKQuantityType.quantityType(forIdentifier: id),
                  store.authorizationStatus(for: quantityType) == .sharingAuthorized else { continue }
            samples.insert(HKQuantitySample(type: quantityType, quantity: HKQuantity(unit: unit, doubleValue: value),
                                            start: at, end: at, metadata: metadata))
        }
        guard !samples.isEmpty else { return nil }
        return HKCorrelation(type: type, start: at, end: at, objects: samples, metadata: metadata)
    }
}
#endif
