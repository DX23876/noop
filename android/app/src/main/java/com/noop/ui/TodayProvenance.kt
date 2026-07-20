package com.noop.ui

import androidx.compose.ui.graphics.Color
import com.noop.analytics.FusionSource
import com.noop.analytics.ReadinessEngine
import com.noop.ble.WhoopBleClient
import com.noop.data.WhoopRepository

/** The Today provenance source for the day's real merge winner. */
internal fun dayOwnerSource(deviceId: String?): FusionSource? = when {
    deviceId == null -> null
    deviceId.endsWith("-noop") -> FusionSource.NOOP_COMPUTED
    deviceId == WhoopRepository.APPLE_HEALTH_SOURCE -> FusionSource.APPLE_HEALTH
    deviceId == WhoopRepository.HEALTH_CONNECT_SOURCE -> FusionSource.HEALTH_CONNECT
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

/** Map a raw resolver source id to the user-facing provenance label used by Today. */
internal fun provenanceDisplayLabel(
    rawSource: String,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String {
    if (rawSource.endsWith("-noop")) return "On-device"
    if (rawSource == deviceId || rawSource == WhoopRepository.WHOOP_SOURCE) return "Whoop"
    if (rawSource == WhoopRepository.APPLE_HEALTH_SOURCE) return "Apple Health"
    return FusionSource.entries.firstOrNull { it.id == rawSource }?.displayName ?: rawSource
}

/** Today uses the audience-facing sensor name for Apple Health scores. */
internal fun todayProvenanceChipLabel(
    rawSource: String,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String = if (rawSource == WhoopRepository.APPLE_HEALTH_SOURCE) {
    "Apple Watch"
} else {
    provenanceDisplayLabel(rawSource, deviceId)
}

/** One compact source label for the liquid score hero. */
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

/** Source label for the three visible hero scores, including carried Charge provenance. */
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

/** Today pull-to-sync mirrors the BLE client's manual-sync guard. */
internal fun todayPullToSyncEnabled(
    connected: Boolean,
    bonded: Boolean,
    backfilling: Boolean,
): Boolean = WhoopBleClient.canRequestSync(connected, bonded, backfilling)

/** Tint for a per-metric provenance badge, keyed on the resolved label. */
internal fun provenanceLabelTint(label: String): Color = when (label) {
    "Whoop" -> Palette.accent
    "Apple Health" -> Palette.metricCyan
    "Health Connect" -> Palette.metricPurple
    else -> Palette.statusPositive
}

/** S4 one-word readiness read kept on the hero. */
internal fun readinessWord(level: ReadinessEngine.Level): String? = when (level) {
    ReadinessEngine.Level.PRIMED -> "Push"
    ReadinessEngine.Level.BALANCED -> "Maintain"
    ReadinessEngine.Level.STRAINED -> "Rest"
    ReadinessEngine.Level.RUNDOWN -> "Rest"
    ReadinessEngine.Level.INSUFFICIENT -> null
}

/** S5 collapsed Data Sources footer summary. */
internal fun syncedFromSummary(hasWhoop: Boolean, hasApple: Boolean, hasHealthConnect: Boolean = false, hasXiaomi: Boolean): String {
    val names = buildList {
        if (hasWhoop) add("WHOOP")
        if (hasApple) add("Apple Watch")
        if (hasHealthConnect) add("Health Connect")
        if (hasXiaomi) add("Mi Band")
    }
    return if (names.isEmpty()) "No sources yet" else "Synced from: " + names.joinToString(", ")
}
