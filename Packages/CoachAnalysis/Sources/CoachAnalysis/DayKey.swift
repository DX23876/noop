import Foundation

/// Arithmetic on `yyyy-MM-dd` local-day keys, the form every NOOP daily series is stored under.
///
/// Days are converted to a plain count since 1970-01-01 with the proleptic Gregorian civil-date algorithm,
/// so stepping a day never meets a time zone or a daylight-saving jump: the keys are already local days,
/// and only their calendar order matters here.
public enum DayKey {

    /// Days since 1970-01-01 for a `yyyy-MM-dd` key, or nil when the key is malformed.
    public static func ordinal(_ key: String) -> Int? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let ordinal = daysFromCivil(year: y, month: m, day: d)
        // Reject a day that does not exist in that month (2026-02-30 would silently roll over).
        guard key == string(ordinal) else { return nil }
        return ordinal
    }

    /// The `yyyy-MM-dd` key for a day count since 1970-01-01.
    public static func string(_ ordinal: Int) -> String {
        let (y, m, d) = civilFromDays(ordinal)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// `key` moved by `days` (negative moves back), or nil when the key is malformed.
    public static func adding(_ days: Int, to key: String) -> String? {
        ordinal(key).map { string($0 + days) }
    }

    /// ISO weekday, 1 = Monday … 7 = Sunday.
    public static func isoWeekday(_ ordinal: Int) -> Int {
        // 1970-01-01 was a Thursday (ISO 4).
        ((ordinal + 3) % 7 + 7) % 7 + 1
    }

    // Howard Hinnant's `days_from_civil` / `civil_from_days`.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}
