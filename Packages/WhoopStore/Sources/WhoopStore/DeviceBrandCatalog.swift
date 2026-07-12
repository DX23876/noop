import Foundation

/// Single source of truth for recognising a wearable BRAND from its advertised BLE name, and the stored
/// facts that follow from the brand. Pure (no CoreBluetooth), so it lives in the store package and is
/// covered by `swift test` — the recognition + capability facts are byte-parity-critical, so they must be
/// asserted headlessly on both platforms. Faithful twin of `android com.noop.data.DeviceBrandCatalog`.
///
/// Adding a recognised brand is ONE row in `all`: the wizard's brand labelling, the experimental-tier
/// capability gate (`ExperimentalBrand`), and the source routing all derive from here instead of re-listing
/// the advertised-name tokens per call site (previously duplicated across `ExperimentalBrand.recognise` and
/// two copies of the wizard's `brandGuess`).
public struct DeviceBrandSpec: Sendable, Equatable {
    /// Display + stored `PairedDevice.brand` string ("Polar", "Amazfit", "Oura", …).
    public let brand: String
    /// Lowercased, diacritic-folded advertised-name substrings that identify this brand. Checked in `all`
    /// order (most specific first) so a Huami sub-brand like Mi Band wins over the broader Amazfit tokens.
    public let nameTokens: [String]
    /// The routing kind stored on the device (drives `SourceCoordinator.makeSource`). `.liveBLE` for a brand
    /// whose live HR is the standard 0x180D broadcast (generic straps + Garmin); `.huami` / `.oura` for the
    /// experimental custom-protocol sources.
    public let sourceKind: SourceKind
    /// The registry id prefix for a device of this brand ("huami", "oura", "garmin", "strap").
    public let idPrefix: String
    /// Whether this brand can stream LIVE heart rate at all in NOOP. `false` for Oura (no open live stream)
    /// — the wizard routes those to import instead of pretending to connect.
    public let canStreamLiveHR: Bool
    /// True for the opt-in EXPERIMENTAL tier (Amazfit / Mi Band / Garmin / Oura); false for the shipped
    /// generic HR straps (Polar / Wahoo / …). `ExperimentalBrand.recognise` returns only these.
    public let isExperimentalTier: Bool

    public init(brand: String, nameTokens: [String], sourceKind: SourceKind, idPrefix: String,
                canStreamLiveHR: Bool, isExperimentalTier: Bool) {
        self.brand = brand
        self.nameTokens = nameTokens
        self.sourceKind = sourceKind
        self.idPrefix = idPrefix
        self.canStreamLiveHR = canStreamLiveHR
        self.isExperimentalTier = isExperimentalTier
    }
}

public enum DeviceBrandCatalog {
    /// The brand table, checked most-specific-first. Order matters ONLY where one name could match two rows:
    /// Mi Band (a Huami sub-brand) precedes Amazfit so a "Mi Smart Band" is not mis-labelled Amazfit. Tokens
    /// are otherwise disjoint across rows, so the remaining order is cosmetic.
    public static let all: [DeviceBrandSpec] = [
        // EXPERIMENTAL tier — custom-protocol or broadcast live sources, opt-in and best-effort.
        DeviceBrandSpec(brand: "Mi Band", nameTokens: ["mi band", "miband", "smart band", "xiaomi"],
                        sourceKind: .huami, idPrefix: "huami", canStreamLiveHR: true, isExperimentalTier: true),
        DeviceBrandSpec(brand: "Amazfit", nameTokens: ["amazfit", "zepp", "helio", "huami"],
                        sourceKind: .huami, idPrefix: "huami", canStreamLiveHR: true, isExperimentalTier: true),
        DeviceBrandSpec(brand: "Garmin",
                        nameTokens: ["garmin", "forerunner", "fenix", "vivoactive", "venu", "instinct", "epix", "vivosmart", "hrm"],
                        sourceKind: .liveBLE, idPrefix: "garmin", canStreamLiveHR: true, isExperimentalTier: true),
        DeviceBrandSpec(brand: "Oura", nameTokens: ["oura"],
                        sourceKind: .oura, idPrefix: "oura", canStreamLiveHR: false, isExperimentalTier: true),
        // Shipped generic HR straps — standard 0x180D broadcast, labelled for display only. All route as a
        // generic live-BLE strap; the wizard picks these through the "Heart-rate strap" type.
        DeviceBrandSpec(brand: "Polar", nameTokens: ["polar"],
                        sourceKind: .liveBLE, idPrefix: "strap", canStreamLiveHR: true, isExperimentalTier: false),
        DeviceBrandSpec(brand: "Wahoo", nameTokens: ["wahoo", "tickr"],
                        sourceKind: .liveBLE, idPrefix: "strap", canStreamLiveHR: true, isExperimentalTier: false),
        DeviceBrandSpec(brand: "Coospo", nameTokens: ["coospo"],
                        sourceKind: .liveBLE, idPrefix: "strap", canStreamLiveHR: true, isExperimentalTier: false),
        DeviceBrandSpec(brand: "Scosche", nameTokens: ["scosche", "rhythm"],
                        sourceKind: .liveBLE, idPrefix: "strap", canStreamLiveHR: true, isExperimentalTier: false),
        DeviceBrandSpec(brand: "Magene", nameTokens: ["magene"],
                        sourceKind: .liveBLE, idPrefix: "strap", canStreamLiveHR: true, isExperimentalTier: false),
    ]

    /// The brand whose advertised name matches, or nil if unrecognised. Diacritic-folded + lowercased so
    /// accented Garmin branding ("vívoactive", "fēnix") matches its ASCII form; substring match in `all`
    /// order. Twin of android `DeviceBrandCatalog.spec(forAdvertisedName:)`.
    public static func spec(forAdvertisedName name: String) -> DeviceBrandSpec? {
        let n = name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        return all.first { spec in spec.nameTokens.contains { n.contains($0) } }
    }

    /// The row for a known brand string ("Amazfit", …), or nil. Lets the typed `ExperimentalBrand` derive
    /// its facts (capability/routing) from this table rather than re-declaring them.
    public static func spec(forBrand brand: String) -> DeviceBrandSpec? {
        all.first { $0.brand == brand }
    }
}
