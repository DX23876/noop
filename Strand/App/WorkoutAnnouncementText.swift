import Foundation
import StrandAnalytics

/// The sentences the live workout's voice speaks. Numbers, durations and distances go through Foundation's
/// own formatters in the app's language ("5 Minuten, 42 Sekunden", "3 kilometres"), so plural and case rules
/// come from the system rather than from per-language string building; only the short sentence frames
/// ("Pace %@ per kilometer.") live in the string catalog.
enum WorkoutAnnouncementText {
    /// The language NOOP's UI runs in, which is also the voice's language.
    static var appLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
    }

    /// "5 minutes, 42 seconds" / "1 hour, 2 minutes" — spelled for speech, never "5:42".
    static func duration(_ seconds: Int, locale: Locale = appLocale) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(max(seconds, 0))) ?? "\(seconds)"
    }

    /// "3 kilometres" / "2.5 miles" in the wearer's distance unit.
    static func distance(_ meters: Double, system: UnitSystem, locale: Locale = appLocale) -> String {
        let measurement = system == .imperial
            ? Measurement(value: meters / 1_609.344, unit: UnitLength.miles)
            : Measurement(value: meters / 1_000, unit: UnitLength.kilometers)
        return measurement.formatted(.measurement(width: .wide, usage: .asProvided,
                                                  numberFormatStyle: .number.precision(.fractionLength(0...1)))
            .locale(locale))
    }

    /// The pace sentence, per kilometre or per mile.
    static func pace(secondsPerSplit: Int, system: UnitSystem, locale: Locale = appLocale) -> String {
        let spoken = duration(secondsPerSplit, locale: locale)
        return system == .imperial
            ? String(localized: "Pace \(spoken) per mile.")
            : String(localized: "Pace \(spoken) per kilometer.")
    }

    /// The target-zone sentence, or nil without a target or a heart rate to judge it by.
    static func zone(bpm: Int?, targetZone: Int?, zoneSet: HRZoneSet) -> String? {
        guard let bpm, let targetZone else { return nil }
        switch HRZoneTrainingEngine.state(forBPM: bpm, zoneSet: zoneSet, targetZone: targetZone) {
        case .inTarget: return String(localized: "In your target zone.")
        case .aboveTarget: return String(localized: "Above your target zone. Ease off.")
        case .belowTarget: return String(localized: "Below your target zone. Pick it up.")
        }
    }

    /// After each split: "3 kilometres. Pace 5 minutes, 42 seconds per kilometer. Time 17 minutes, 5 seconds.
    /// Heart rate 148. In your target zone."
    static func split(index: Int, secondsPerSplit: Int, elapsedSeconds: Int, averageBpm: Int?,
                      zoneLine: String?, system: UnitSystem, locale: Locale = appLocale) -> String {
        let splitMeters = system == .imperial ? 1_609.344 : 1_000
        var parts = ["\(distance(Double(index) * splitMeters, system: system, locale: locale)).",
                     pace(secondsPerSplit: secondsPerSplit, system: system, locale: locale),
                     String(localized: "Time \(duration(elapsedSeconds, locale: locale)).")]
        if let averageBpm { parts.append(String(localized: "Heart rate \(averageBpm).")) }
        if let zoneLine { parts.append(zoneLine) }
        return parts.joined(separator: " ")
    }

    /// Every interval without a route: time, and heart rate and Effort only when they were measured.
    static func interval(elapsedSeconds: Int, averageBpm: Int?, effort: String?, zoneLine: String?,
                         locale: Locale = appLocale) -> String {
        var parts = [String(localized: "Time \(duration(elapsedSeconds, locale: locale)).")]
        if let averageBpm { parts.append(String(localized: "Heart rate \(averageBpm).")) }
        if let effort { parts.append(String(localized: "Effort \(effort).")) }
        if let zoneLine { parts.append(zoneLine) }
        return parts.joined(separator: " ")
    }

    /// The end-of-workout recap: distance, time and average pace with a route, time alone without one.
    static func summary(elapsedSeconds: Int, distanceMeters: Double?, system: UnitSystem,
                        locale: Locale = appLocale) -> String {
        let time = duration(elapsedSeconds, locale: locale)
        var parts = [String(localized: "Workout ended.")]
        let splitMeters = system == .imperial ? 1_609.344 : 1_000
        if let distanceMeters, distanceMeters >= 100 {
            parts.append(String(localized: "\(distance(distanceMeters, system: system, locale: locale)) in \(time)."))
            let perSplit = Int((Double(elapsedSeconds) / (distanceMeters / splitMeters)).rounded())
            parts.append(system == .imperial
                ? String(localized: "Average pace \(duration(perSplit, locale: locale)) per mile.")
                : String(localized: "Average pace \(duration(perSplit, locale: locale)) per kilometer."))
        } else {
            parts.append(String(localized: "Time \(time)."))
        }
        return parts.joined(separator: " ")
    }
}
