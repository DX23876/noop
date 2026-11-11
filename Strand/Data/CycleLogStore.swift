import Foundation
import WhoopStore

// MARK: - Cycle day log (flow, symptoms, mood)
//
// What a wearer notes about a cycle day, beside the period start. Stored like the period start: one
// metricSeries row per fact under the isolated `noop-cycle` source, so an import or a re-analysis can never
// overwrite it and no schema change is needed. Flow is one row keyed `flow` with the level as its value;
// each symptom and each mood is its own value-1 row (`symptom.cramps`, `mood.irritable`), and clearing one
// is a real row delete. None of it feeds the cycle estimate, which reads the nights and the logged starts.

// The log's storage and keys are shared with the Android core (`CycleLog` in `CycleReading.swift`); the iPhone
// adds the names it shows.
extension CycleLog {
    /// The ids with their display names, in the order the sheet shows them.
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
}

extension CycleLog.Flow {
    var title: String {
        switch self {
        case .spotting: return String(localized: "Spotting")
        case .light: return String(localized: "Light")
        case .medium: return String(localized: "Medium")
        case .heavy: return String(localized: "Heavy")
        }
    }
}

extension Repository {

    /// Every logged cycle day in the range, by "yyyy-MM-dd".
    func cycleLog(from: String, to: String) async -> [String: CycleLog.Day] {
        guard let store = await storeHandle() else { return [:] }
        return await CycleLog.read(store: store, from: from, to: to)
    }

    /// Replace one day's notes with `log`: rows that are no longer set are deleted, not zeroed.
    func saveCycleLog(day: String, _ log: CycleLog.Day, previous: CycleLog.Day) async {
        guard let store = await storeHandle() else { return }
        await CycleLog.save(store: store, day: day, log, previous: previous)
        noteCycleTrackingChanged()
    }

    /// Saves today's notes, logging a new period start when flow begins with none in the last ten days.
    func saveCycleLogLoggingStart(day: String, _ log: CycleLog.Day, previous: CycleLog.Day, starts: [String]) async {
        guard let store = await storeHandle() else { return }
        await CycleLog.saveLoggingStart(store: store, day: day, log, previous: previous, starts: starts)
        noteCycleTrackingChanged()
    }
}
