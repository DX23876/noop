#if os(iOS)
import Foundation
import HealthKit
import WhoopStore

/// Idempotent quantity/category updates. Saves precede legacy cleanup, and durable versions survive
/// process death between the Health transaction and local acknowledgement.
@MainActor
enum HealthSampleWriter {
    static func query(type: HKSampleType, predicate: NSPredicate, store: HKHealthStore) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else if let samples { continuation.resume(returning: samples) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
            store.execute(query)
        }
    }

    static func fingerprint(_ sample: HKSample) throws -> String {
        let value: String
        if let quantity = sample as? HKQuantitySample { value = quantity.quantity.description }
        else if let category = sample as? HKCategorySample { value = String(category.value) }
        else { throw CocoaError(.validationMissingMandatoryProperty) }
        var metadata = sample.metadata ?? [:]
        metadata.removeValue(forKey: HKMetadataKeySyncIdentifier)
        metadata.removeValue(forKey: HKMetadataKeySyncVersion)
        let encoded = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        return [sample.sampleType.identifier, String(sample.startDate.timeIntervalSince1970),
                String(sample.endDate.timeIntervalSince1970), value, String(decoding: encoded, as: UTF8.self)].joined(separator: "|")
    }

    static func save(_ samples: [HKSample], store: HKHealthStore, db: WhoopStore) async throws -> Int {
        guard !samples.isEmpty else { return 0 }
        let ids = try samples.map { sample -> String in
            guard let id = (sample.metadata?[HKMetadataKeySyncIdentifier] as? String)
                ?? (sample.metadata?[HKMetadataKeyExternalUUID] as? String) else { throw CocoaError(.validationMissingMandatoryProperty) }
            return sample.sampleType.identifier + "|" + id
        }
        let versions = try await db.planHealthExports(try zip(ids, samples).map { (id: $0.0, fingerprint: try fingerprint($0.1)) })
        var pending: [(HKSample, HealthSyncState.ExportVersion)] = []
        for (sample, version) in zip(samples, versions) where version.needsSave {
            var metadata = sample.metadata ?? [:]
            metadata[HKMetadataKeySyncIdentifier] = version.id
            metadata[HKMetadataKeySyncVersion] = NSNumber(value: version.revision)
            let replacement: HKSample
            if let quantity = sample as? HKQuantitySample {
                replacement = HKQuantitySample(type: quantity.quantityType, quantity: quantity.quantity,
                    start: quantity.startDate, end: quantity.endDate, metadata: metadata)
            } else if let category = sample as? HKCategorySample {
                replacement = HKCategorySample(type: category.categoryType, value: category.value,
                    start: category.startDate, end: category.endDate, metadata: metadata)
            } else { throw CocoaError(.validationMissingMandatoryProperty) }
            pending.append((replacement, version))
        }
        for offset in stride(from: 0, to: pending.count, by: 5_000) {
            try Task.checkCancellation()
            let chunk = Array(pending[offset..<min(pending.count, offset + 5_000)])
            try await store.save(chunk.map { $0.0 })
            HealthSyncStats.recordSaved(chunk.count)
            try await db.commitHealthExports(chunk.map { $0.1 })
        }
        // Metadata UUIDs do not enforce uniqueness. Retire only observed legacy objects AFTER the
        // versioned replacement is durable; retrying cleanup is safe even when the payload was unchanged.
        let byType = Dictionary(grouping: samples, by: \.sampleType)
        let now = Date().timeIntervalSince1970
        for (type, values) in byType {
            let keys = Set(values.compactMap { $0.metadata?[HKMetadataKeyExternalUUID] as? String })
            let first = values.map(\.startDate).min() ?? .now
            let last = values.map(\.endDate).max() ?? .now
            let windowStart = first.addingTimeInterval(-86_400).timeIntervalSince1970
            let cleanKey = legacyCleanKeyPrefix + type.identifier
            let clean = UserDefaults.standard.array(forKey: cleanKey) as? [Double]
            if canSkipLegacyCheck(clean: clean, windowStart: windowStart, now: now) { continue }
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(from: HKSource.default()),
                HKQuery.predicateForSamples(withStart: first.addingTimeInterval(-86_400), end: last.addingTimeInterval(86_400), options: [])
            ])
            let legacy = try await query(type: type, predicate: predicate, store: store).filter {
                guard $0.metadata?[HKMetadataKeySyncIdentifier] == nil,
                      let key = $0.metadata?[HKMetadataKeyExternalUUID] as? String else { return false }
                return keys.contains(canonicalExternalKey(key))
            }
            if legacy.isEmpty {
                UserDefaults.standard.set(cleanRecord(previous: clean, windowStart: windowStart, now: now), forKey: cleanKey)
            } else {
                try await store.delete(legacy)
                HealthSyncStats.recordDeleted(legacy.count)
                UserDefaults.standard.removeObject(forKey: cleanKey)
            }
        }
        return samples.count
    }

    /// The legacy sweep above reads every NOOP sample of the type in the window, a few thousand heart
    /// rate samples, and runs on every save. Once a window has come back clean, the same span is skipped
    /// for a day. A save reaching further back than the clean span (a history repair) still sweeps, and
    /// the daily recheck covers legacy objects that come back, for example from a restored backup.
    static let legacyCleanKeyPrefix = "health.legacyClean.v1."
    static let legacyRecheckSeconds: Double = 86_400

    /// `clean` is `[earliest clean window start, time of that check]`, both Unix seconds.
    nonisolated static func canSkipLegacyCheck(clean: [Double]?, windowStart: Double, now: Double) -> Bool {
        guard let clean, clean.count == 2 else { return false }
        let age = now - clean[1]
        return age >= 0 && age < legacyRecheckSeconds && windowStart >= clean[0]
    }

    /// The record after a clean sweep: the earliest clean start still inside the recheck day is kept, so
    /// a short recent save does not shrink a span a longer save already proved clean.
    nonisolated static func cleanRecord(previous: [Double]?, windowStart: Double, now: Double) -> [Double] {
        if let previous, previous.count == 2, now - previous[1] >= 0, now - previous[1] < legacyRecheckSeconds {
            return [min(previous[0], windowStart), previous[1]]
        }
        return [windowStart, now]
    }

    static func canonicalExternalKey(_ key: String) -> String {
        var parts = key.split(separator: ":").map(String.init)
        if parts.count == 4, parts.first == "noop", !["workout", "sleep", "hr", "diag"].contains(parts[1]) { parts.remove(at: 1) }
        return parts.joined(separator: ":")
    }
}
#endif
