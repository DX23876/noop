package com.noop.ui

import androidx.compose.ui.graphics.Color
import com.noop.analytics.FusionSource
import com.noop.analytics.ReadinessEngine
import com.noop.ble.WhoopBleClient
import com.noop.data.WhoopRepository

/**
 * The Today provenance label for the day's REAL merge winner, extends the existing By-Day badge
 * vocabulary consistently. NOOP-computed reads "On-device" (the spec's wording for the By-Day badge,
 * versus the FusedRecord screen's terser "NOOP"), an imported strap day reads "Whoop", and a phone
 * aggregate reads "Apple Health" / "Health Connect". Null when no source owns the day (nothing to
 * stamp). Mirrors the Swift `provenanceBadgeLabel`.
 */
internal fun dayOwnerSource(deviceId: String?): FusionSource? = when {
    deviceId == null -> null
    deviceId.endsWith("-noop") -> FusionSource.NOOP_COMPUTED
    deviceId == WhoopRepository.APPLE_HEALTH_SOURCE -> FusionSource.APPLE_HEALTH
    deviceId == WhoopRepository.HEALTH_CONNECT_SOURCE -> FusionSource.HEALTH_CONNECT
    // The merged Today rows carry the imported strap deviceId ("my-whoop") on days a real WHOOP import
    // covers, and the "-noop" sibling otherwise; any other strap deviceId is still an imported strap day.
    else -> FusionSource.WHOOP_IMPORT
}

internal fun provenanceBadgeLabel(owner: FusionSource?): String? = when (owner) {
    FusionSource.NOOP_COMPUTED -> "On-device"
    FusionSource.WHOOP_IMPORT -> "Whoop"
    FusionSource.APPLE_HEALTH -> "Apple Health"
    FusionSource.HEALTH_CONNECT -> "Health Connect"
    FusionSource.XIAOMI_BAND -> "Mi Band"
    FusionSource.NUTRITION_CSV -> "Nutrition"
    FusionSource.LOCAL_CACHE -> "Cached"
    null -> null
}

/**
 * PURE mapper (unit-tested), a RAW resolver source id (as returned by [WhoopRepository.resolvedSeries]'s
 * winning point, e.g. "my-whoop", "my-whoop-noop", "apple-health") onto the spec's provenance labels,
 * given the strap's real [deviceId]. ANY NOOP-computed strap sibling (a "-noop"-suffixed id, not just the
 * active strap's) reads "On-device" - matching by suffix rather than "$deviceId-noop" so a computed row
 * from a non-active strap can't fall through to [FusionSource.NOOP_COMPUTED]'s raw "NOOP" displayName
 * (the internal id must never surface); the imported strap source ([deviceId], normally "my-whoop") reads
 * "Whoop"; the Apple-Health source reads "Apple Health". Any other real source (Health Connect, Mi Band,
 * nutrition) keeps its [FusionSource.displayName], still the genuine merge winner, never a blanket claim.
 * Mirrors the Swift `provenanceDisplayLabel` EXACTLY. This is the PER-METRIC mapper the Today rings use;
 * the day-level [dayOwnerSource]/[provenanceBadgeLabel] pair stays for the legacy By-Day vocabulary.
 */
internal fun provenanceDisplayLabel(
    rawSource: String,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String {
    if (rawSource.endsWith("-noop")) return "On-device"
    if (rawSource == deviceId || rawSource == WhoopRepository.WHOOP_SOURCE) return "Whoop"
    if (rawSource == WhoopRepository.APPLE_HEALTH_SOURCE) return "Apple Health"
    // Fall back to the FusionSource display name for any other known source; else the raw id verbatim.
    return FusionSource.entries.firstOrNull { it.id == rawSource }?.displayName ?: rawSource
}

/** Today uses the audience-facing sensor name for Apple Health scores, matching the Swift Today lane. */
internal fun todayProvenanceChipLabel(
    rawSource: String,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String = if (rawSource == WhoopRepository.APPLE_HEALTH_SOURCE) {
    "Apple Watch"
} else {
    provenanceDisplayLabel(rawSource, deviceId)
}

/**
 * One compact source label for the liquid score hero. Raw winners arrive in Charge / Effort / Rest order;
 * identical display names collapse and mixed winners are capped at two so the badge stays readable.
 * Mirrors LiquidTodayView.heroSourceLabel value-for-value.
 */
internal fun heroSourceLabel(
    rawSources: List<String>,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String? {
    val labels = LinkedHashSet<String>()
    for (rawSource in rawSources) {
        labels.add(todayProvenanceChipLabel(rawSource, deviceId))
        if (labels.size == 2) break
    }
    return labels.takeIf { it.isNotEmpty() }?.joinToString(" + ")
}

/**
 * Source label for the three visible hero scores. Today can show a carried Charge from the previous
 * scored night while today's recovery is still absent (#543); in that state the selected-day
 * "recovery" provenance is also absent, so use the carried night's resolved recovery source instead of
 * letting the card badge omit or misrepresent the visible Charge (#390).
 */
internal fun scoreHeroSourceLabel(
    provenanceByMetric: Map<String, String>,
    carriedRecoverySource: String?,
    usesCarriedRecovery: Boolean,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String? {
    val recoverySource = provenanceByMetric["recovery"]
        ?: if (usesCarriedRecovery) carriedRecoverySource else null
    return heroSourceLabel(
        rawSources = listOfNotNull(
            recoverySource,
            provenanceByMetric["strain"],
            provenanceByMetric["sleep_performance"],
        ),
        deviceId = deviceId,
    )
}

/** Today pull-to-sync mirrors the BLE client's manual-sync guard, so the gesture never starts a sync while
 *  disconnected, still bonding, or already offloading. Kept pure for the UI-specific contract test. */
internal fun todayPullToSyncEnabled(
    connected: Boolean,
    bonded: Boolean,
    backfilling: Boolean,
): Boolean = WhoopBleClient.canRequestSync(connected, bonded, backfilling)

/** The tint for a per-metric provenance badge, keyed on the resolved LABEL, gold for Whoop, cyan for
 *  Apple Health, the positive status hue for on-device (and anything else). Matches the Data Sources
 *  footer + the Swift `provenanceTint` so the same source reads the same colour on Today. */
internal fun provenanceLabelTint(label: String): Color = when (label) {
    "Whoop" -> Palette.accent
    "Apple Health" -> Palette.metricCyan
    "Health Connect" -> Palette.metricPurple
    else -> Palette.statusPositive
}

/**
 * S4 (#205): the one-word readiness read kept on the hero (Push / Maintain / Rest) now the full Readiness
 * card folded into the Charge-ring tap. PURE mapping of the existing [ReadinessEngine.Level]; INSUFFICIENT
 * returns null (the hero then shows no word, matching the old card hiding itself). Byte-identical twin of
 * the Swift TodayView.readinessWord.
 */
internal fun readinessWord(level: ReadinessEngine.Level): String? = when (level) {
    ReadinessEngine.Level.PRIMED -> "Push"
    ReadinessEngine.Level.BALANCED -> "Maintain"
    ReadinessEngine.Level.STRAINED -> "Rest"
    ReadinessEngine.Level.RUNDOWN -> "Rest"
    ReadinessEngine.Level.INSUFFICIENT -> null
}

/**
 * S5: the collapsed Data Sources footer summary, "Synced from: WHOOP, Apple Watch", listing only sources
 * with data (Apple Health reads as "Apple Watch", the device the audience knows), or "No sources yet".
 * PURE + unit-tested. Twin of the Swift TodayView.syncedFromSummary, plus the Android-only
 * hasHealthConnect source - Health Connect is named for what it is, never folded under "Apple Watch"
 * (issue #176).
 */
internal fun syncedFromSummary(hasWhoop: Boolean, hasApple: Boolean, hasHealthConnect: Boolean = false, hasXiaomi: Boolean): String {
    val names = buildList {
        if (hasWhoop) add("WHOOP")
        if (hasApple) add("Apple Watch")
        if (hasHealthConnect) add("Health Connect")
        if (hasXiaomi) add("Mi Band")
    }
    return if (names.isEmpty()) "No sources yet" else "Synced from: " + names.joinToString(", ")
}
