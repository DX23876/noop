import Foundation
import StrandAnalytics
import StrandCore

// RhythmAgeSnapshot.swift — fork feature "Daily rhythm" (CosinorAge beta): the stored readout and the plain words
// about it, shared by the Apple app and the Android core (parity plan 2.3). Scores nothing itself; the daily pass
// stored the readout.

// MARK: - Stored readout

enum RhythmAgeSnapshot: Equatable {
    struct Reading: Equatable {
        let day: String
        let advance: Double
        let mesor: Double
        let amplitude: Double
        let peakHour: Double
        let sdYears: Double?
        /// Average movement per local clock hour on that day's window, 24 entries, nil where unobserved.
        var hourly: [Double?] = Array(repeating: nil, count: 24)
    }

    case empty
    case collecting(hours: Double)
    case reading(Reading)

    private typealias K = DailyAnalysis

    /// The newest scored day, keyed `series[key][day]`. Only that day counts, so an older reading never stands
    /// in for a newer day that is still collecting.
    static func latest(_ series: [String: [String: Double]]) -> RhythmAgeSnapshot {
        guard let day = series[K.rhythmHoursKey]?.keys.max(), let hours = series[K.rhythmHoursKey]?[day] else {
            return .empty
        }
        guard let advance = series[K.rhythmAdvanceKey]?[day], let mesor = series[K.rhythmMesorKey]?[day],
              let amplitude = series[K.rhythmAmplitudeKey]?[day], let peak = series[K.rhythmPeakKey]?[day] else {
            return .collecting(hours: hours)
        }
        return .reading(Reading(day: day, advance: advance, mesor: mesor, amplitude: amplitude, peakHour: peak,
                                sdYears: series[K.rhythmSDKey]?[day],
                                hourly: (0..<24).map { series[K.rhythmHourKey($0)]?[day] }))
    }

    /// Every stored rhythm age, oldest first, for the history chart.
    static func history(_ series: [String: [String: Double]]) -> [(day: String, advance: Double)] {
        (series[K.rhythmAdvanceKey] ?? [:]).sorted { $0.key < $1.key }.map { (day: $0.key, advance: $0.value) }
    }

    @MainActor
    static func load(repo: any HealthspanSeriesReading) async -> (RhythmAgeSnapshot, [(day: String, advance: Double)]) {
        var series: [String: [String: Double]] = [:]
        for key in DailyAnalysis.rhythmKeys {
            series[key] = Dictionary(await repo.healthspanSeries(key: key, days: 400)
                .map { ($0.day, $0.value) }, uniquingKeysWith: { _, b in b })
        }
        return (latest(series), history(series))
    }
}

// MARK: - Words

enum RhythmAgeText {
    private typealias Part = RhythmAge.PartOfDay

    /// One or two plain sentences on what the hour chart shows: the part of the day that matches the study best,
    /// then the part or parts where movement falls well short. nil when the day is not fully observed.
    static func daySentence(_ hourly: [Double?]) -> String? {
        let levels = RhythmAge.partLevels(hourly)
        guard levels.count == Part.allCases.count else { return nil }
        let below = Part.allCases.filter { levels[$0] == .below }
        if below.count == Part.allCases.count {
            return String(localized: "You move much less than most people all day.")
        }
        let strong = Part.allCases.first { levels[$0] == .above } ?? Part.allCases.first { levels[$0] == .typical }
        var sentences: [String] = []
        if let strong { sentences.append(goodPart(strong, more: levels[strong] == .above)) }
        if !below.isEmpty { sentences.append(lessIn(below)) }
        return sentences.joined(separator: " ")
    }

    private static func goodPart(_ p: Part, more: Bool) -> String {
        switch (p, more) {
        case (.morning, false): return String(localized: "In the morning you move like most people.")
        case (.morning, true): return String(localized: "In the morning you move more than most people.")
        case (.afternoon, false): return String(localized: "In the afternoon you move like most people.")
        case (.afternoon, true): return String(localized: "In the afternoon you move more than most people.")
        case (.evening, false): return String(localized: "In the evening you move like most people.")
        case (.evening, true): return String(localized: "In the evening you move more than most people.")
        }
    }

    private static func lessIn(_ parts: [Part]) -> String {
        switch Set(parts) {
        case [.morning]: return String(localized: "In the morning much less.")
        case [.afternoon]: return String(localized: "In the afternoon much less.")
        case [.evening]: return String(localized: "In the evening much less.")
        case [.morning, .afternoon]: return String(localized: "In the morning and afternoon much less.")
        case [.morning, .evening]: return String(localized: "In the morning and evening much less.")
        default: return String(localized: "In the afternoon and evening much less.")
        }
    }

    /// The one concrete step: where movement is missing, or a nudge to keep going.
    static func lever(_ r: RhythmAgeSnapshot.Reading) -> String {
        let levels = RhythmAge.partLevels(r.hourly)
        if levels.count == RhythmAge.PartOfDay.allCases.count,
           let first = RhythmAge.PartOfDay.allCases.first(where: { levels[$0] == .below }),
           levels.values.contains(where: { $0 != .below }) {
            switch first {
            case .morning: return String(localized: "Get up for a few minutes every hour in the morning. That is where you're missing movement.")
            case .afternoon: return String(localized: "Get up for a few minutes every hour in the afternoon. That is where you're missing movement.")
            case .evening: return String(localized: "Get up for a few minutes every hour in the evening. That is where you're missing movement.")
            }
        }
        if RhythmAge.movementLevel(mesorMg: r.mesor) == .below || RhythmAge.contrastLevel(amplitudeMg: r.amplitude) == .below {
            return String(localized: "Get up for a few minutes every hour of the day. That gives your day more movement and a clearer rhythm.")
        }
        return String(localized: "Your day moves like most people's. Keep it that way.")
    }

}

