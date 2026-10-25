package com.noop.ui

import com.noop.data.WhoopRepository
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the By-Day source badge (Sleep overhaul §2.6). The card used to hard-code "NOOP-computed" on
 * EVERY row — even days an import won the dashboard merge — so a user couldn't tell a strap-scored
 * night from an imported one. The badge now derives from the merged DailyMetric's WINNING deviceId:
 *   - computed "<id>-noop"        → "On-device"
 *   - imported WHOOP export        → "Whoop"
 *   - apple-health / health-connect → "Apple Health"
 * Brand wording matches macOS IntelligenceEngine.DaySource.badge. Mirrors WorkoutSourceLabelTest.
 */
class IntelligenceDaySourceBadgeTest {

    @Test
    fun computedNoopRow_isOnDevice() {
        assertEquals("On-device", daySourceBadge("my-whoop-noop").first)
    }

    @Test
    fun anyNoopSuffix_isOnDevice() {
        // A non-default strap id keeps the "-noop" computed suffix convention.
        assertEquals("On-device", daySourceBadge("strap-abc123-noop").first)
    }

    @Test
    fun whoopImportRow_isWhoop() {
        // The merged row keeps the imported "my-whoop" id when a WHOOP export wins the merge.
        assertEquals("Whoop", daySourceBadge("my-whoop").first)
    }

    @Test
    fun appleHealthRow_isAppleHealth() {
        assertEquals("Apple Health", daySourceBadge(WhoopRepository.APPLE_HEALTH_SOURCE).first)
    }

    @Test
    fun healthConnectRow_isAppleHealth() {
        // Health Connect is the Android twin of Apple Health — same badge, not a Whoop fall-through.
        assertEquals("Apple Health", daySourceBadge(WhoopRepository.HEALTH_CONNECT_SOURCE).first)
    }

    @Test
    fun computedTintDiffersFromImportTint() {
        // Computed rows keep the charge tint; imports use the accent tint so they stand out.
        assertEquals(Palette.chargeColor, daySourceBadge("my-whoop-noop").second)
        assertEquals(Palette.accent, daySourceBadge("my-whoop").second)
    }

    @Test
    fun noBadgeLabelCarriesAnEmDash() {
        for (id in listOf("my-whoop-noop", "my-whoop", "apple-health", "health-connect")) {
            assertEquals(false, daySourceBadge(id).first.contains("—"))
        }
    }
}
