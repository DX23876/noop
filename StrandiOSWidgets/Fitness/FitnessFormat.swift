import Foundation

/// The few ways the fitness widgets write numbers, in one place so all ten read alike.
enum FitnessFormat {
    /// "7 h 18 min", "45 min".
    static func duration(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? String(localized: "\(m / 60) h \(m % 60) min") : String(localized: "\(m) min")
    }

    /// Hours and minutes as a clock reads: "1:35". For tight places such as a stage legend.
    static func clock(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// A whole number in the reader's grouping: "10,300".
    static func whole(_ value: Double) -> String { Int(value.rounded()).formatted() }

    /// One decimal at most: "81.3", "14.6".
    static func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// A stored day key as a short date: "Mon 5 Oct".
    static func day(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return key }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// The last non-nil value of a series and whether it is the last day's (today's).
    static func latest<T>(_ series: [T?]) -> (value: T, isLastDay: Bool)? {
        guard let index = series.lastIndex(where: { $0 != nil }), let value = series[index] else { return nil }
        return (value, index == series.count - 1)
    }
}
