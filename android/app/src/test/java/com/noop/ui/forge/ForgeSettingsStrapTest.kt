package com.noop.ui.forge

import com.noop.R
import com.noop.ui.StepsCalibrationFormat
import com.noop.ui.strapStatusDetail
import com.noop.ui.strapStatusTitle
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The Forge Strap page words the link with resources; the classic Strap card words it with literals. Both must read
 * the same three facts the same way, so one link never says two different things on two screens.
 */
class ForgeSettingsStrapTest {
    private val flags = listOf(false, true)

    @Test
    fun theLinkStateFollowsTheClassicTitleForEveryCombination() {
        val titles = mapOf(
            StrapLinkState.Streaming to "Bonded · streaming",
            StrapLinkState.Idle to "Bonded · idle",
            StrapLinkState.LiveOnly to "Live HR (not fully paired)",
            StrapLinkState.Connected to "Connected",
            StrapLinkState.Disconnected to "Disconnected",
        )
        for (encrypted in flags) for (bonded in flags) for (connected in flags) {
            assertEquals("encrypted=$encrypted bonded=$bonded connected=$connected",
                         strapStatusTitle(encrypted, bonded, connected), titles.getValue(strapLinkState(encrypted, bonded, connected)))
        }
    }

    @Test
    fun theDetailSentenceFollowsTheClassicOneForEveryCombination() {
        // Each resource stands for the classic sentence it translates; the live-HR-only one is told apart by its opening.
        val openings = mapOf(
            R.string.fsp2_detail_searching to "Searching for your WHOOP",
            R.string.fsp2_detail_paired to "Your strap is paired and sending data",
            R.string.fsp2_detail_live_only to "Live heart rate is streaming",
            R.string.fsp2_detail_finishing to "Connected. Finishing the secure pairing",
            R.string.fsp2_detail_previous to "Previously paired but not currently connected",
            R.string.fsp2_detail_none to "No strap connected",
        )
        for (encrypted in flags) for (bonded in flags) for (connected in flags) for (scanning in flags) {
            val opening = openings.getValue(strapLinkDetailRes(encrypted, bonded, connected, scanning))
            val classic = strapStatusDetail(encrypted, bonded, connected, scanning)
            assertEquals("encrypted=$encrypted bonded=$bonded connected=$connected scanning=$scanning: $classic",
                         true, classic.startsWith(opening))
        }
    }

    @Test
    fun theConfidenceWordsFollowTheClassicThirds() {
        val words = mapOf(R.string.fsp2_confidence_low to "Low", R.string.fsp2_confidence_medium to "Medium",
                          R.string.fsp2_confidence_high to "High")
        for (c in listOf(0.0, 0.2, 0.33, 0.34, 0.5, 0.66, 0.67, 0.9, 1.0)) {
            assertEquals("confidence=$c", StepsCalibrationFormat.confidenceLabel(c), words.getValue(strapConfidenceRes(c)))
        }
    }
}
