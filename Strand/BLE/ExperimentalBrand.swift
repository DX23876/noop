import Foundation
import WhoopStore

/// CLEAN-ROOM best-effort recognition of the EXPERIMENTAL band families from an advertised device name.
///
/// This is a thin TYPED VIEW over `DeviceBrandCatalog` (the pure, `swift test`-covered single source of
/// truth in WhoopStore): the advertised-name tokens and capability facts live there once, and this enum
/// only names the four experimental families so the drivers can switch on them (`== .garmin`, etc.).
/// Deliberately conservative: a name we don't recognise returns `nil` rather than a wrong guess. NOTHING
/// here fabricates data — it only labels a discovered peripheral so the experimental add-device flow can
/// show the honest per-brand guidance.
public enum ExperimentalBrand: String, CaseIterable, Sendable, Equatable {
    /// Amazfit / Zepp / Huami family (incl. the Helio ring/band). Live HR is best-effort: standard
    /// 0x180D where exposed, else the documented Huami custom HR characteristic.
    case amazfit
    /// Xiaomi Mi Band (Huami-family). Older bands expose HR on a custom char; newer need an auth
    /// handshake we can't do — the driver surfaces that honestly rather than faking it.
    case miBand
    /// Garmin watch. Live HR is the STANDARD broadcast-HR path (0x180D) when the user enables
    /// "Broadcast Heart Rate" on the watch — there is no NOOP-proprietary Garmin protocol.
    case garmin
    /// Oura ring. No open live health stream — proprietary, syncs to Oura's own app. The driver makes
    /// the detection attempt and then points honestly at file import.
    case oura

    /// Best-effort brand from an advertised name. Returns `nil` for an unrecognised name, OR for a name the
    /// catalog recognises as a NON-experimental generic strap (Polar / Wahoo / …) — `ExperimentalBrand`
    /// names only the experimental tier. All token matching lives in `DeviceBrandCatalog`.
    public static func recognise(name: String) -> ExperimentalBrand? {
        guard let spec = DeviceBrandCatalog.spec(forAdvertisedName: name), spec.isExperimentalTier else {
            return nil
        }
        return ExperimentalBrand(displayBrand: spec.brand)
    }

    /// The brand label stored on the registry row / shown in the UI. Human, US-neutral, no claims. This is
    /// the case ⇄ catalog-brand bridge, so it must match a `DeviceBrandCatalog` row's `brand` exactly (a
    /// test pins that).
    public var displayBrand: String {
        switch self {
        case .amazfit: return "Amazfit"
        case .miBand:  return "Mi Band"
        case .garmin:  return "Garmin"
        case .oura:    return "Oura"
        }
    }

    /// Whether this brand can stream LIVE heart rate at all in NOOP's experimental tier. Derived from the
    /// catalog (`false` for Oura — no open live stream — so the wizard routes those to file import instead
    /// of pretending to connect). Defaults to `false` if the catalog row is somehow missing (a test pins
    /// that every case resolves).
    public var canStreamLiveHR: Bool {
        DeviceBrandCatalog.spec(forBrand: displayBrand)?.canStreamLiveHR ?? false
    }

    /// The routing kind stored on a device of this brand (from the catalog). Drives `SourceCoordinator`.
    /// Falls back to `.liveBLE` (a standard-HR strap — never steals the WHOOP path) if the row is missing.
    public var sourceKind: SourceKind {
        DeviceBrandCatalog.spec(forBrand: displayBrand)?.sourceKind ?? .liveBLE
    }

    /// The registry id prefix for a device of this brand (from the catalog); "strap" fallback. The device
    /// `id` (== sample deviceId) is `"<idPrefix>-<uuid>"`, so this MUST stay byte-identical to the value the
    /// wizard previously hardcoded — a test pins each experimental brand's prefix.
    public var idPrefix: String {
        DeviceBrandCatalog.spec(forBrand: displayBrand)?.idPrefix ?? "strap"
    }

    /// Map a catalog brand string back to the typed case (nil for a non-experimental brand).
    private init?(displayBrand brand: String) {
        switch brand {
        case "Amazfit": self = .amazfit
        case "Mi Band": self = .miBand
        case "Garmin":  self = .garmin
        case "Oura":    self = .oura
        default:        return nil
        }
    }
}
