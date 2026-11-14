package com.noop.ingest

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which selected data Health Connect grants nothing for. The case this answers: an install that was
 * granted recovery data long ago and later learned to read workouts imports everything except workouts,
 * and a count of granted permissions names neither the gap nor the fix.
 */
class HealthConnectGrantGapTest {

    private val recovery = HealthConnectImporter.ImportCategory.RECOVERY
    private val activity = HealthConnectImporter.ImportCategory.ACTIVITY

    @Test
    fun `a category with no grant at all is named`() {
        val granted = setOf(HealthPermission.getReadPermission(HeartRateRecord::class))
        val gaps = HealthConnectImporter.categoriesWithoutGrant(setOf(recovery, activity), granted)
        assertEquals(listOf(activity.storageKey), gaps)
    }

    /** One grant inside a category is enough to take it off the list: the import runs on partial grants
     *  (#150), so a category is only a gap when NOTHING in it is readable. */
    @Test
    fun `one grant inside a category takes it off the list`() {
        val granted = setOf(HealthPermission.getReadPermission(ExerciseSessionRecord::class))
        val gaps = HealthConnectImporter.categoriesWithoutGrant(setOf(activity), granted)
        assertTrue(gaps.isEmpty())
    }

    @Test
    fun `nothing granted names every selected category`() {
        val gaps = HealthConnectImporter.categoriesWithoutGrant(setOf(recovery, activity), emptySet())
        assertEquals(listOf(recovery.storageKey, activity.storageKey), gaps)
    }

    /** Workouts live in Activity, which is what makes the gap above the one a wearer notices. */
    @Test
    fun `workouts are read under the activity category`() {
        val activityPermissions = HealthConnectImporter.permissionsFor(setOf(activity))
        assertTrue(HealthPermission.getReadPermission(ExerciseSessionRecord::class) in activityPermissions)
    }
}
