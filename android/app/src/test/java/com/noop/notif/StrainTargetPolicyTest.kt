package com.noop.notif

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure gate + copy of the #593 optimal-strain-reached notification (the ScheduledReportPolicy /
 * BatteryAlertPolicy crossing-dedupe idiom). The Android notifier just wires this to a channel + the
 * persisted day marker, so all the decision logic is verified here without android.*. Contract: fire at
 * most once per day, only when strain has genuinely reached a KNOWN target, never on a guessed one.
 */
class StrainTargetPolicyTest {

    @Test fun firesWhenEnabledStrainReachedTargetAndNotYetToday() {
        assertTrue(
            StrainTargetPolicy.shouldNotify(
                enabled = true, dayStrain = 14.0, target = 14.0, lastNotifiedDay = "2026-07-17", today = "2026-07-18",
            ),
        )
        // Overshooting the target still fires (>= gate), once.
        assertTrue(
            StrainTargetPolicy.shouldNotify(
                enabled = true, dayStrain = 16.2, target = 14.0, lastNotifiedDay = null, today = "2026-07-18",
            ),
        )
    }

    @Test fun suppressedWhenDisabled() {
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = false, dayStrain = 18.0, target = 14.0, lastNotifiedDay = null, today = "2026-07-18",
            ),
        )
    }

    @Test fun suppressedBeforeTargetIsReached() {
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = true, dayStrain = 13.9, target = 14.0, lastNotifiedDay = null, today = "2026-07-18",
            ),
        )
    }

    @Test fun suppressedWhenAlreadyFiredToday() {
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = true, dayStrain = 15.0, target = 14.0, lastNotifiedDay = "2026-07-18", today = "2026-07-18",
            ),
        )
    }

    @Test fun suppressedWhenTargetUnknownCalibrating() {
        // Null recovery ⇒ no optimal band ⇒ null target ⇒ never fire (never guess a target).
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = true, dayStrain = 18.0, target = null, lastNotifiedDay = null, today = "2026-07-18",
            ),
        )
    }

    @Test fun suppressedWhenNoStrainYet() {
        assertFalse(
            StrainTargetPolicy.shouldNotify(
                enabled = true, dayStrain = null, target = 14.0, lastNotifiedDay = null, today = "2026-07-18",
            ),
        )
    }

    @Test fun copyUsesNoopWordingAndTheTarget() {
        val (title, body) = StrainTargetPolicy.copy(target = 14)
        // NOOP's own copy — must NOT reproduce WHOOP's decompiled strings.
        assertTrue(title.contains("Optimal strain"))
        assertFalse(title.contains("Target Strain Reached"))
        assertTrue(body.contains("14"))
        assertFalse(body.contains("for this activity"))
    }
}
