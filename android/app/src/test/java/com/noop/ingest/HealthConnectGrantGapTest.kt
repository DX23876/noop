package com.noop.ingest

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import com.noop.ingest.HealthConnectImporter.ImportCategory
import com.noop.ingest.HealthConnectImporter.ImportType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which selected data Health Connect grants nothing for. The case this answers: an install that was
 * granted recovery data long ago and later learned to read workouts imports everything except workouts,
 * and a count of granted permissions names neither the gap nor the fix.
 */
class HealthConnectGrantGapTest {

    private val recovery = ImportCategory.RECOVERY.types.toSet()
    private val training = ImportCategory.TRAINING.types.toSet()

    @Test
    fun `a group with no grant at all is named`() {
        val granted = setOf(HealthPermission.getReadPermission(HeartRateRecord::class))
        val gaps = HealthConnectImporter.categoriesWithoutGrant(recovery + training, granted)
        assertEquals(listOf(ImportCategory.TRAINING.storageKey), gaps)
    }

    /** One grant inside a group is enough to take it off the list: the import runs on partial grants
     *  (#150), so a group is only a gap when NOTHING selected in it is readable. */
    @Test
    fun `one grant inside a group takes it off the list`() {
        val granted = setOf(HealthPermission.getReadPermission(ExerciseSessionRecord::class))
        val gaps = HealthConnectImporter.categoriesWithoutGrant(training, granted)
        assertTrue(gaps.isEmpty())
    }

    @Test
    fun `nothing granted names every selected group`() {
        val gaps = HealthConnectImporter.categoriesWithoutGrant(recovery + training, emptySet())
        assertEquals(listOf(ImportCategory.RECOVERY.storageKey, ImportCategory.TRAINING.storageKey), gaps)
    }

    /** A group the wearer selected nothing in is not a gap, however little Android grants there. */
    @Test
    fun `an unselected group is never named`() {
        val gaps = HealthConnectImporter.categoriesWithoutGrant(setOf(ImportType.STEPS), emptySet())
        assertEquals(listOf(ImportCategory.STEPS.storageKey), gaps)
    }

    /** Workouts live in Training, which is what makes the gap above the one a wearer notices. */
    @Test
    fun `workouts are read under the training group`() {
        val trainingPermissions = HealthConnectImporter.permissionsFor(training)
        assertTrue(HealthPermission.getReadPermission(ExerciseSessionRecord::class) in trainingPermissions)
    }
}
