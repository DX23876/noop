import Foundation

// MARK: - ChargeBand — the ONE definition of what a Charge score means
//
// Before this, the app carried three competing answers to "is 62 a good Charge?":
//   • the gradient stops (`StrandPalette.recoveryStops`, locations 0 / .30 / .55 / .78 / 1.00),
//   • the state words (`StrandPalette.recoveryState`, thresholds 25 / 50 / 70 / 88),
//   • and WHOOP's own 33 / 66 split, which parts of the product copy lean on.
// With no canonical band, a ring colour and the sentence beside it could disagree about the same
// number. This enum is that canonical band; `recoveryState(_:)` now derives its word from here, so
// there is exactly one threshold list in the codebase.
//
// THRESHOLDS ARE THE ONES ALREADY SHIPPED (25 / 50 / 70 / 88), deliberately NOT WHOOP's 33 / 66: the
// five words are already translated in the catalog and quoted by the Charge explanation, so moving the
// boundaries would silently change what existing, already-translated sentences mean.
//
// Split from the colour lookup on purpose, and for a reason the codebase learned once already at
// `ChargeSyncIndicator.chargeBand(_:)`: a SwiftUI `Color` wraps a dynamic catalog colour in a fresh
// provider per access, so two reads of one palette token are not `==`. A test asserting on the colour
// would compare identities rather than the banding it means to check. So the BAND is what is pinned by
// tests; the colour hangs off it.
//
// Lives in StrandDesign rather than StrandAnalytics because StrandDesign is deliberately
// dependency-free and watchOS-safe, and it is the only module every Charge surface imports — the Today
// hero, both iOS widgets, the watch glance and the watch complications. StrandAnalytics does not depend
// on StrandDesign, so a band declared there could not have reached the palette at all. Pure Foundation:
// no SwiftUI, no clock, no I/O.
public enum ChargeBand: String, CaseIterable, Equatable, Sendable {
    case depleted
    case low
    case moderate
    case primed
    case peak

    /// The band a 0...100 Charge score falls in. A boundary belongs to the band ABOVE it (a score of
    /// exactly 70 reads `primed`, not `moderate`), matching the `..<` cases the state words shipped with.
    public static func of(score: Double) -> ChargeBand {
        switch score {
        case ..<25: return .depleted
        case ..<50: return .low
        case ..<70: return .moderate
        case ..<88: return .primed
        default:    return .peak
        }
    }

    /// The uppercase state word for this band (§9.3): DEPLETED · LOW · MODERATE · PRIMED · PEAK.
    /// Localized from the package catalog, which is why every caller must go through the package bundle.
    public var word: String {
        switch self {
        case .depleted: return String(localized: "DEPLETED", bundle: .module)
        case .low:      return String(localized: "LOW", bundle: .module)
        case .moderate: return String(localized: "MODERATE", bundle: .module)
        case .primed:   return String(localized: "PRIMED", bundle: .module)
        case .peak:     return String(localized: "PEAK", bundle: .module)
        }
    }
}
