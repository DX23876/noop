import Foundation
import WhoopStore

// MARK: - Cycle day log (flow, symptoms, mood)
//
// What a wearer notes about a cycle day, beside the period start. Stored like the period start: one
// metricSeries row per fact under the isolated `noop-cycle` source, so an import or a re-analysis can never
// overwrite it and no schema change is needed. Flow is one row keyed `flow` with the level as its value;
// each symptom and each mood is its own value-1 row (`symptom.cramps`, `mood.irritable`), and clearing one
// is a real row delete. None of it feeds the cycle estimate, which reads the nights and the logged starts.

enum CycleLog {
    static let flowKey = "flow"
    static let symptomPrefix = "symptom."
    static let moodPrefix = "mood."

    enum Flow: Int, CaseIterable, Identifiable {
        case spotting = 1, light, medium, heavy
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .spotting: return String(localized: "Spotting")
            case .light: return String(localized: "Light")
            case .medium: return String(localized: "Medium")
            case .heavy: return String(localized: "Heavy")
            }
        }
    }

    /// Stable ids (they are storage keys) with their display names, in the order the sheet shows them.
    static let symptoms: [(id: String, title: String)] = [
        ("cramps", String(localized: "Cramps")), ("headache", String(localized: "Headache")),
        ("bloating", String(localized: "Bloating")), ("tender_breasts", String(localized: "Tender breasts")),
        ("back_pain", String(localized: "Back pain")), ("acne", String(localized: "Acne")),
        ("tired", String(localized: "Tired")), ("cravings", String(localized: "Cravings")),
    ]
    static let moods: [(id: String, title: String)] = [
        ("calm", String(localized: "Calm")), ("happy", String(localized: "Happy")),
        ("irritable", String(localized: "Irritable")), ("low", String(localized: "Low")),
        ("anxious", String(localized: "Anxious")), ("sensitive", String(localized: "Sensitive")),
    ]

    /// One day's notes.
    struct Day: Equatable {
        var flow: Flow?
        var symptoms: Set<String> = []
        var moods: Set<String> = []
        var isEmpty: Bool { flow == nil && symptoms.isEmpty && moods.isEmpty }
    }
}

extension Repository {

    /// Every logged cycle day in the range, by "yyyy-MM-dd".
    func cycleLog(from: String, to: String) async -> [String: CycleLog.Day] {
        guard let store = await storeHandle() else { return [:] }
        let keys = ((try? await store.metricKeys(deviceId: CycleTrackingStore.sourceId)) ?? [])
            .filter { $0 == CycleLog.flowKey || $0.hasPrefix(CycleLog.symptomPrefix) || $0.hasPrefix(CycleLog.moodPrefix) }
        var out: [String: CycleLog.Day] = [:]
        for key in keys {
            let rows = (try? await store.metricSeries(deviceId: CycleTrackingStore.sourceId, key: key, from: from, to: to)) ?? []
            for row in rows {
                var day = out[row.day] ?? CycleLog.Day()
                if key == CycleLog.flowKey {
                    day.flow = CycleLog.Flow(rawValue: Int(row.value.rounded()))
                } else if key.hasPrefix(CycleLog.symptomPrefix), row.value >= 1 {
                    day.symptoms.insert(String(key.dropFirst(CycleLog.symptomPrefix.count)))
                } else if key.hasPrefix(CycleLog.moodPrefix), row.value >= 1 {
                    day.moods.insert(String(key.dropFirst(CycleLog.moodPrefix.count)))
                }
                out[row.day] = day
            }
        }
        return out
    }

    /// Replace one day's notes with `log`: rows that are no longer set are deleted, not zeroed.
    func saveCycleLog(day: String, _ log: CycleLog.Day, previous: CycleLog.Day) async {
        guard let store = await storeHandle() else { return }
        let source = CycleTrackingStore.sourceId
        var upserts: [MetricPoint] = []
        var deletes: [String] = []
        if let flow = log.flow {
            upserts.append(MetricPoint(day: day, key: CycleLog.flowKey, value: Double(flow.rawValue)))
        } else if previous.flow != nil {
            deletes.append(CycleLog.flowKey)
        }
        for id in log.symptoms { upserts.append(MetricPoint(day: day, key: CycleLog.symptomPrefix + id, value: 1)) }
        for id in previous.symptoms.subtracting(log.symptoms) { deletes.append(CycleLog.symptomPrefix + id) }
        for id in log.moods { upserts.append(MetricPoint(day: day, key: CycleLog.moodPrefix + id, value: 1)) }
        for id in previous.moods.subtracting(log.moods) { deletes.append(CycleLog.moodPrefix + id) }
        if !upserts.isEmpty { _ = try? await store.upsertMetricSeries(upserts, deviceId: source) }
        for key in deletes { _ = try? await store.deleteMetricSeriesPoint(deviceId: source, day: day, key: key) }
        noteCycleTrackingChanged()
    }
}
