import Foundation

/// Version-string comparison for the in-app "Check for updates". Lives here because this package is
/// the one with a unit-test target; the comparison is the only part with a real bug risk (a plain
/// string compare gets `1.40` vs `1.39` and `1.9` vs `1.10` WRONG).
public enum VersionCheck {

    /// True iff `latest` is a strictly newer version than `current`. Compares dot-separated numeric
    /// segments left to right (so `1.40 > 1.39` and `1.9 < 1.10`). Tolerant of a leading "v" and any
    /// non-numeric suffix (e.g. build metadata or a "-demo" flavour tag).
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = segments(latest)
        let b = segments(current)
        for i in 0..<Swift.max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The numeric core of a version or tag, for SHOWING to someone: `"v10.1.0-dx"` → `"10.1.0"`.
    ///
    /// The comparison above already ignores a suffix; this is the same rule applied to the string the
    /// update sheet prints, so the two cannot disagree about what "the latest version" is called. The
    /// fork's tags carry a `-dx` marker to stay out of upstream's tag namespace — that is a fact about
    /// the tag, not about the release, and it has no business in a sentence read by a user. Falls back
    /// to the trimmed input when there is no numeric core at all, so an unexpected tag still shows
    /// something rather than an empty string.
    public static func displayVersion(_ s: String) -> String {
        var v = Substring(s.trimmingCharacters(in: .whitespaces))
        if v.first == "v" || v.first == "V" { v = v.dropFirst() }
        let core = v.prefix { $0.isNumber || $0 == "." }
        let trimmed = core.hasSuffix(".") ? core.dropLast() : core
        return trimmed.isEmpty ? String(v) : String(trimmed)
    }

    static func segments(_ s: String) -> [Int] {
        var v = Substring(s.trimmingCharacters(in: .whitespaces))
        if v.first == "v" || v.first == "V" { v = v.dropFirst() }
        let core = v.prefix { $0.isNumber || $0 == "." }   // stop at "-demo" / build metadata
        return core.split(separator: ".").compactMap { Int($0) }
    }
}
