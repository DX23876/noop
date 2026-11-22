import Foundation

/// How far back a historical import reads, as a wearer chooses it.
///
/// Swift twin of `android/app/src/main/java/com/noop/ingest/ImportDepth.kt`, same four steps and the same
/// month counts, each side pinned by its own test.
///
/// Fork (DX23876), 2026-11-22. The Android Health Connect import took a ten-year window on every run,
/// including the automatic one every few hours, and a tester's phone read 2 269 462 records in one pass
/// that way. The Apple side is in much better shape — ordinary syncing is anchored and incremental, and
/// the body-composition lookback is a sparse discrete read — but it has the same decision in one place:
/// the wearer-triggered full-history import, which reads ten years because that is what the sparse
/// lookback uses. That is the import this offers a choice for.
///
/// The longest step is named for what it is. Ten years is the furthest either importer has read, which is
/// not the same claim as "everything Apple Health holds".
public enum ImportDepth: Int, CaseIterable, Sendable {
    case oneMonth = 1
    case oneYear = 12
    case threeYears = 36
    case tenYears = 120

    /// Months back from today.
    public var months: Int { rawValue }

    /// Days back from today, which is what the HealthKit sync window takes. A month is counted as 30 and
    /// a year as 365: the import re-aggregates whole days from a start date, so a few days either way
    /// changes which days are read, never how any of them is computed.
    public var days: Int { Int((Double(months) * 365.0 / 12.0).rounded()) }

    /// What an import uses when the wearer has not chosen.
    public static let `default`: ImportDepth = .oneYear

    /// The step a stored month count belongs to, `default` for anything else. A stored value that no step
    /// matches comes from a build that offered different steps; falling back is how the chooser stays
    /// readable across such a change, and never an error on a settings read.
    public static func ofMonths(_ months: Int) -> ImportDepth {
        ImportDepth(rawValue: months) ?? .default
    }
}
