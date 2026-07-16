package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #510: `fillWorkoutHrFromStrap` used to read every workout's HR window under a hardcoded "my-whoop",
 * so a workout recorded on a SECOND WHOOP (id "whoop-<mac>", its HR banked under that id) read an empty
 * window and lost its Avg HR / calories / Effort. [WhoopRepository.workoutHrDeviceId] now resolves the
 * correct read key per row; this pins that resolution and the strap-native classification it rides on.
 */
class WorkoutHrDeviceKeyTest {

    @Test fun `strap-native sources are classified as strap-native`() {
        assertTrue(WhoopRepository.isStrapNativeWorkout("manual"))
        assertTrue(WhoopRepository.isStrapNativeWorkout("MANUAL"))          // case-insensitive
        assertTrue(WhoopRepository.isStrapNativeWorkout("my-whoop-noop"))   // detected (canonical)
        assertTrue(WhoopRepository.isStrapNativeWorkout("whoop-aabbcc-noop")) // detected (2nd WHOOP)
    }

    @Test fun `imported sources are NOT strap-native`() {
        assertFalse(WhoopRepository.isStrapNativeWorkout("apple-health"))
        assertFalse(WhoopRepository.isStrapNativeWorkout("Apple Health"))
        assertFalse(WhoopRepository.isStrapNativeWorkout("Health Connect"))
        assertFalse(WhoopRepository.isStrapNativeWorkout("activity-file"))
        assertFalse(WhoopRepository.isStrapNativeWorkout("lifting"))
        assertFalse(WhoopRepository.isStrapNativeWorkout("my-whoop"))       // WHOOP CSV import (ends -whoop, not -noop)
    }

    @Test fun `detected row reads HR under its own base strap, not the active strap`() {
        // A detected bout on a SECOND WHOOP lives under "whoop-aabbcc-noop"; its HR is banked under
        // "whoop-aabbcc". The active strap being something else must NOT redirect the read.
        assertEquals(
            "whoop-aabbcc",
            WhoopRepository.workoutHrDeviceId("whoop-aabbcc-noop", "whoop-aabbcc-noop", activeStrapId = "my-whoop"),
        )
        // Canonical single-WHOOP detected row is unchanged from the old "my-whoop" behaviour.
        assertEquals(
            "my-whoop",
            WhoopRepository.workoutHrDeviceId("my-whoop-noop", "my-whoop-noop", activeStrapId = "my-whoop"),
        )
    }

    @Test fun `manual row reads HR under its own strap id`() {
        assertEquals(
            "whoop-aabbcc",
            WhoopRepository.workoutHrDeviceId("manual", "whoop-aabbcc", activeStrapId = "my-whoop"),
        )
    }

    @Test fun `imported row reads HR under the active strap (the worn strap), preserving the #77 fill`() {
        // An Apple/HC/activity-file row carries no strap HR; #77 fills it from the worn strap = active strap.
        assertEquals(
            "whoop-aabbcc",
            WhoopRepository.workoutHrDeviceId("apple-health", "apple-health", activeStrapId = "whoop-aabbcc"),
        )
        assertEquals(
            "my-whoop",
            WhoopRepository.workoutHrDeviceId("activity-file", "activity-file", activeStrapId = "my-whoop"),
        )
    }

    @Test fun `a bare strap id with no -noop suffix is returned unchanged`() {
        // removeSuffix is a no-op when the suffix is absent — a manual/base id must not be truncated.
        assertEquals(
            "whoop-aabbcc",
            WhoopRepository.workoutHrDeviceId("manual", "whoop-aabbcc", activeStrapId = "ignored"),
        )
    }
}
