package com.noop.data

import java.text.Normalizer

/**
 * Single source of truth for recognising a wearable BRAND from its advertised BLE name, and the stored
 * facts that follow from the brand. Pure (no android.bluetooth) so it's JVM-unit-tested — the recognition
 * + capability facts are byte-parity-critical and must be asserted headlessly on both platforms. Faithful
 * twin of Packages/WhoopStore/Sources/WhoopStore/DeviceBrandCatalog.swift.
 *
 * Adding a recognised brand is ONE row in [all]: the wizard's brand labelling ([brandGuess]), the
 * experimental-tier gate ([com.noop.ble.ExperimentalBrand]), and the source routing all derive from here
 * instead of re-listing the advertised-name tokens per call site.
 */
data class DeviceBrandSpec(
    /** Display + stored `PairedDeviceRow.brand` string ("Polar", "Amazfit", "Oura", …). */
    val brand: String,
    /** Lowercased, diacritic-folded advertised-name substrings that identify this brand. Checked in [all]
     *  order (most specific first) so a Huami sub-brand like Mi Band wins over the broader Amazfit tokens. */
    val nameTokens: List<String>,
    /** The routing kind stored on the device (drives `SourceCoordinator.makeSource`). [SourceKind.liveBLE]
     *  for a brand whose live HR is the standard 0x180D broadcast (generic straps + Garmin); [SourceKind.huami]
     *  / [SourceKind.oura] for the experimental custom-protocol sources. */
    val sourceKind: SourceKind,
    /** The registry id prefix for a device of this brand ("huami", "oura", "garmin", "strap"). */
    val idPrefix: String,
    /** Whether this brand can stream LIVE heart rate at all in NOOP. false for Oura (no open live stream) —
     *  the wizard routes those to import instead of pretending to connect. */
    val canStreamLiveHR: Boolean,
    /** True for the opt-in EXPERIMENTAL tier (Amazfit / Mi Band / Garmin / Oura); false for the shipped
     *  generic HR straps (Polar / Wahoo / …). `ExperimentalBrand.recognise` returns only these. */
    val isExperimentalTier: Boolean,
)

object DeviceBrandCatalog {
    /** The brand table, checked most-specific-first. Order matters ONLY where one name could match two rows:
     *  Mi Band (a Huami sub-brand) precedes Amazfit so a "Mi Smart Band" is not mis-labelled Amazfit. Tokens
     *  are otherwise disjoint across rows, so the remaining order is cosmetic. */
    val all: List<DeviceBrandSpec> = listOf(
        // EXPERIMENTAL tier — custom-protocol or broadcast live sources, opt-in and best-effort.
        DeviceBrandSpec("Mi Band", listOf("mi band", "miband", "smart band", "xiaomi"),
            SourceKind.huami, "huami", canStreamLiveHR = true, isExperimentalTier = true),
        DeviceBrandSpec("Amazfit", listOf("amazfit", "zepp", "helio", "huami"),
            SourceKind.huami, "huami", canStreamLiveHR = true, isExperimentalTier = true),
        DeviceBrandSpec("Garmin",
            listOf("garmin", "forerunner", "fenix", "vivoactive", "venu", "instinct", "epix", "vivosmart", "hrm"),
            SourceKind.liveBLE, "garmin", canStreamLiveHR = true, isExperimentalTier = true),
        DeviceBrandSpec("Oura", listOf("oura"),
            SourceKind.oura, "oura", canStreamLiveHR = false, isExperimentalTier = true),
        // Shipped generic HR straps — standard 0x180D broadcast, labelled for display only.
        DeviceBrandSpec("Polar", listOf("polar"),
            SourceKind.liveBLE, "strap", canStreamLiveHR = true, isExperimentalTier = false),
        DeviceBrandSpec("Wahoo", listOf("wahoo", "tickr"),
            SourceKind.liveBLE, "strap", canStreamLiveHR = true, isExperimentalTier = false),
        DeviceBrandSpec("Coospo", listOf("coospo"),
            SourceKind.liveBLE, "strap", canStreamLiveHR = true, isExperimentalTier = false),
        DeviceBrandSpec("Scosche", listOf("scosche", "rhythm"),
            SourceKind.liveBLE, "strap", canStreamLiveHR = true, isExperimentalTier = false),
        DeviceBrandSpec("Magene", listOf("magene"),
            SourceKind.liveBLE, "strap", canStreamLiveHR = true, isExperimentalTier = false),
    )

    /** The brand whose advertised name matches, or null if unrecognised. Diacritic-folded (NFD + strip
     *  combining marks, mirroring Swift's `.diacriticInsensitive`) + lowercased; substring match in [all]
     *  order. Twin of Swift `DeviceBrandCatalog.spec(forAdvertisedName:)`. */
    fun specForAdvertisedName(name: String): DeviceBrandSpec? {
        val n = Normalizer.normalize(name, Normalizer.Form.NFD)
            .replace(Regex("\\p{M}+"), "")
            .lowercase()
        return all.firstOrNull { spec -> spec.nameTokens.any { n.contains(it) } }
    }

    /** The row for a known brand string ("Amazfit", …), or null. Lets the typed `ExperimentalBrand` derive
     *  its facts (capability/routing) from this table rather than re-declaring them. */
    fun specForBrand(brand: String): DeviceBrandSpec? = all.firstOrNull { it.brand == brand }
}
