import Foundation
import StrandAnalytics
import WhoopStore

/// Read-only session physiology. Chart and zones resolve the recording source by the same rule.
public enum WorkoutPhysiology {
    public static func deviceIds(source: String, activeStrapId: String, importedIds: [String]) -> [String] {
        if source.hasPrefix("native-training:"),
           let trackerId = source.split(separator: ":", maxSplits: 1).last.map(String.init), !trackerId.isEmpty {
            return [trackerId]
        }
        if WorkoutSource.classify(source) == .oura { return importedIds + [WorkoutSource.ouraSource] }
        guard WorkoutSource.classify(source) == .detected else { return importedIds }
        return [source.hasSuffix("-noop") ? String(source.dropLast(5)) : source]
    }

    public static func bucketSeconds(from: Int, to: Int) -> Int {
        max(15, min(300, (to - from) / 120))
    }

    public static func buckets(reader: StoreReader, from: Int, to: Int, source: String = "") async -> [HRBucket] {
        guard to > from else { return [] }
        let ids = deviceIds(source: source, activeStrapId: reader.activeDeviceId, importedIds: reader.importedReadIds)
        return await reader.hrBuckets(deviceIds: ids, from: from, to: to,
                                      bucketSeconds: bucketSeconds(from: from, to: to))
    }

    public static func zoneMinutes(reader: StoreReader, from: Int, to: Int, zoneSet: HRZoneSet,
                                    source: String = "") async -> [Double]? {
        guard to > from else { return nil }
        let ids = deviceIds(source: source, activeStrapId: reader.activeDeviceId, importedIds: reader.importedReadIds)
        let samples = await reader.hrSamples(deviceIds: ids, from: from, to: to)
        guard !samples.isEmpty else { return nil }
        let minutes = HRZones.timeInZone(samples, zoneSet: zoneSet).seconds.map { $0 / 60 }
        return minutes.contains(where: { $0 > 0 }) ? minutes : nil
    }
}
