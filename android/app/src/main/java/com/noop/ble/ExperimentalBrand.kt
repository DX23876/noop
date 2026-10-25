package com.noop.ble

import com.noop.data.DeviceBrandCatalog
import com.noop.data.SourceKind

/**
 * CLEAN-ROOM best-effort recognition of the EXPERIMENTAL band families from an advertised device name.
 *
 * Faithful Kotlin twin of Strand/BLE/ExperimentalBrand.swift. A thin TYPED VIEW over [DeviceBrandCatalog]
 * (the pure, JVM-unit-tested single source of truth in com.noop.data): the advertised-name tokens and
 * capability facts live there once, and this enum only names the four experimental families so the drivers
 * can switch on them. Deliberately conservative: an unrecognised name returns null rather than a wrong
 * guess. NOTHING here fabricates data — it only labels a discovered peripheral so the experimental
 * add-device flow can show the honest per-brand guidance. US English throughout.
 */
enum class ExperimentalBrand(val displayBrand: String) {
    /** Amazfit / Zepp / Huami family (incl. Helio ring/band). Best-effort live HR: standard 0x180D where
     *  exposed, else the documented Huami custom HR characteristic. */
    AMAZFIT("Amazfit"),
    /** Xiaomi Mi Band (Huami-family). Older bands expose HR on a custom char; newer need an auth handshake
     *  we can't do — the driver surfaces that honestly rather than faking it. */
    MI_BAND("Mi Band"),
    /** Garmin watch. Live HR is the STANDARD broadcast-HR path (0x180D) when the user enables
     *  "Broadcast Heart Rate" — there is no NOOP-proprietary Garmin protocol. */
    GARMIN("Garmin"),
    /** Oura ring. No open live health stream — proprietary, syncs to Oura's app. The driver makes the
     *  detection attempt, then points honestly at file import. */
    OURA("Oura");

    /** Whether this brand can stream LIVE heart rate at all, derived from the catalog (false for Oura — no
     *  open live stream — so the wizard routes it to import). false if the catalog row is somehow missing. */
    val canStreamLiveHR: Boolean
        get() = DeviceBrandCatalog.specForBrand(displayBrand)?.canStreamLiveHR ?: false

    /** Routing kind stored on a device of this brand (from the catalog); liveBLE fallback (a standard-HR
     *  strap — never steals the WHOOP path). */
    val sourceKind: SourceKind
        get() = DeviceBrandCatalog.specForBrand(displayBrand)?.sourceKind ?: SourceKind.liveBLE

    /** Registry id prefix for a device of this brand (from the catalog); "strap" fallback. The device id
     *  (== sample deviceId) is "<idPrefix>-<address>", so this MUST stay byte-identical to the value the
     *  wizard previously hardcoded — a test pins each experimental brand's prefix. */
    val idPrefix: String
        get() = DeviceBrandCatalog.specForBrand(displayBrand)?.idPrefix ?: "strap"

    companion object {
        /** Best-effort brand from an advertised name. Returns null for an unrecognised name, OR for a name
         *  the catalog recognises as a NON-experimental generic strap (Polar / Wahoo / …). All token
         *  matching lives in [DeviceBrandCatalog]. */
        fun recognise(name: String): ExperimentalBrand? {
            val spec = DeviceBrandCatalog.specForAdvertisedName(name) ?: return null
            if (!spec.isExperimentalTier) return null
            return values().firstOrNull { it.displayBrand == spec.brand }
        }
    }
}
