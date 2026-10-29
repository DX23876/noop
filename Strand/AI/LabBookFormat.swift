import Foundation
import StrandImport

// MARK: - Shared formatting (decimals from the catalog; UTC day labels)

enum LabBookFormat {
    /// Format a numeric value with the marker's catalog decimals. A custom (non-catalog) marker has no
    /// declared precision, so it is shown at its own precision via `plain` rather than a fixed 1 decimal,
    /// which rounded plateletcrit 0.27 to "0.3" and urine specific gravity 1.020 to "1.0".
    static func value(_ v: Double, key: String) -> String {
        guard v.isFinite else { return "—" }
        guard let decimals = MarkerCatalog.definition(for: key)?.decimals else { return plain(v) }
        return decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
    }

    /// Up to 3 decimals with trailing zeros dropped ("0.27", "1.02", "140"), always with a "." separator
    /// whatever the device locale (`String(format:)` without a locale is POSIX). A value that rounds to
    /// zero prints "0", never "-0"; a non-finite value prints "—". Twin: `LabValueFormat.plain` (Android);
    /// both are pinned by the same expected strings in `LabBookFormatTests` / `LabValueFormatTest`.
    static func plain(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// "12 Jun 2026" for a takenAt epoch-seconds value.
    static func day(_ epoch: Int) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// "12 Jun 2026" rendered from a stored `yyyy-MM-dd` day string, LOCATION-INDEPENDENTLY: the day key
    /// is parsed in UTC and reformatted in UTC, so the history date never shifts with the device zone the
    /// way `day(takenAt)` (a local render of a stored instant) can near midnight. Falls back to the raw
    /// string if it doesn't parse.
    static func dayFromKey(_ day: String) -> String {
        guard let date = utcKeyFormatter.date(from: day) else { return day }
        return utcDayFormatter.string(from: date)
    }

    /// "d MMM yyyy" pinned to UTC, paired with `utcKeyFormatter` so `dayFromKey` round-trips a UTC day.
    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// The `yyyy-MM-dd` day key the projection uses (LOCAL day of the reading).
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayKey(_ date: Date) -> String { keyFormatter.string(from: date) }

    /// A `yyyy-MM-dd` parser PINNED to UTC, so a day string always maps to the same instant regardless
    /// of the device zone. The local-zone `keyFormatter` above returns nil for a day whose LOCAL midnight
    /// is skipped by a DST transition (e.g. Chile/Cuba, 06 Sep) - which used to collapse `noonEpoch` to
    /// epoch 0 and collide different days on the natural key. UTC never skips midnight.
    private static let utcKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Epoch seconds of UTC noon on a `yyyy-MM-dd` day — the deterministic, LOCATION-INDEPENDENT `takenAt`
    /// for CSV-imported readings, so re-importing the same file (even after travel to another zone) upserts
    /// in place instead of minting a duplicate (natural key deviceId+markerKey+takenAt+source). Pinned to
    /// UTC so a DST-skipped local midnight can never collapse the key to epoch 0. 0 only for a genuinely
    /// unparseable day string. History dates render from the stored `day` string, not this takenAt.
    static func noonEpoch(_ day: String) -> Int {
        guard let midnight = utcKeyFormatter.date(from: day) else { return 0 }
        return Int(midnight.timeIntervalSince1970) + 12 * 3600
    }
}
