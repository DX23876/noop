package com.noop.ingest

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.TotalCaloriesBurnedRecord
import androidx.health.connect.client.records.WeightRecord
import com.noop.ingest.HealthConnectImporter.ImportCategory
import com.noop.ingest.HealthConnectImporter.ImportType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure coverage for the per-type consent contract (#645, reworked 2026-11-14). */
class HealthConnectPermissionCategoryTest {
    private val recovery = ImportCategory.RECOVERY.types.toSet()
    private val body = ImportCategory.BODY_COMPOSITION.types.toSet()

    private fun perm(type: kotlin.reflect.KClass<out androidx.health.connect.client.records.Record>) =
        HealthPermission.getReadPermission(type)

    @Test
    fun everyTypeHasItsOwnPermissionAndSitsInExactlyOneGroup() {
        val permissions = ImportType.entries.map { it.permission }
        assertEquals(permissions.size, permissions.toSet().size)
        assertEquals(HealthConnectImporter.PERMISSIONS, permissions.toSet())

        val grouped = ImportCategory.entries.flatMap { it.types }
        assertEquals(ImportType.entries.size, grouped.size)
        assertEquals(ImportType.entries.toSet(), grouped.toSet())
    }

    @Test
    fun recoveryDoesNotRequestActivityOrBodyComposition() {
        val permissions = HealthConnectImporter.permissionsFor(recovery)

        assertTrue(perm(HeartRateRecord::class) in permissions)
        assertFalse(perm(StepsRecord::class) in permissions)
        assertFalse(perm(WeightRecord::class) in permissions)
    }

    /** The tester's wish: steps and training without calories. */
    @Test
    fun stepsAndTrainingAskForNoCalories() {
        val permissions = HealthConnectImporter.permissionsFor(
            ImportCategory.STEPS.types.toSet() + ImportCategory.TRAINING.types,
        )

        assertTrue(perm(StepsRecord::class) in permissions)
        assertTrue(perm(ExerciseSessionRecord::class) in permissions)
        assertFalse(perm(TotalCaloriesBurnedRecord::class) in permissions)
        assertFalse(perm(ActiveCaloriesBurnedRecord::class) in permissions)
    }

    @Test
    fun newInstallsDefaultNarrowWhileLegacyInstallsKeepExistingImports() {
        assertEquals(
            recovery,
            HealthConnectImporter.typesFromLegacyCategoryKeys(null, hadLegacyPermissionSignature = false),
        )
        assertEquals(
            HealthConnectImporter.ALL_TYPES,
            HealthConnectImporter.typesFromLegacyCategoryKeys(null, hadLegacyPermissionSignature = true),
        )
    }

    /** The old "activity" group read steps, calories and training; converting it narrows nothing. */
    @Test
    fun oldActivitySelectionCarriesOverWhole() {
        assertEquals(
            ImportCategory.STEPS.types.toSet() + ImportCategory.TRAINING.types + ImportCategory.CALORIES.types + body,
            HealthConnectImporter.typesFromLegacyCategoryKeys(
                setOf("activity", "body-composition"),
                hadLegacyPermissionSignature = true,
            ),
        )
    }

    /** Switching everything off is a choice, not a missing value: it must not fall back to a default. */
    @Test
    fun anEmptyStoredSelectionStaysEmpty() {
        assertTrue(HealthConnectImporter.typesFromStoredKeys(emptySet()).isEmpty())
        assertTrue(HealthConnectImporter.requestFor(emptySet()).isEmpty())
    }

    @Test
    fun storedTypesRoundTrip() {
        val chosen = setOf(ImportType.STEPS, ImportType.WORKOUTS, ImportType.VO2_MAX)
        assertEquals(chosen, HealthConnectImporter.typesFromStoredKeys(chosen.mapTo(HashSet()) { it.storageKey }))
    }

    @Test
    fun narrowingNeverRepromptsAndExpandingRequestsOnlyNewTypes() {
        val recoveryPermissions = HealthConnectImporter.requestFor(recovery)

        assertTrue(HealthConnectImporter.unaskedPermissions(recoveryPermissions, recovery).isEmpty())
        assertEquals(
            HealthConnectImporter.permissionsFor(body),
            HealthConnectImporter.unaskedPermissions(recoveryPermissions, recovery + body),
        )
    }

    @Test
    fun aWearerAskedBeforeTheHistoryPermissionIsAskedForItOnce() {
        // Asked under the old rule: the data types only. The history permission is new, so it is asked for once.
        val oldAsk = HealthConnectImporter.permissionsFor(recovery)
        assertEquals(setOf(HealthConnectImporter.HISTORY_PERMISSION),
                     HealthConnectImporter.unaskedPermissions(oldAsk, recovery))
        assertTrue(HealthConnectImporter.HISTORY_PERMISSION in HealthConnectImporter.requestFor(recovery))
    }

    /**
     * Owner decision 2026-11-14: a type declined in Health Connect's own screen is not asked for again on
     * the next tap. Asked before and still not granted means "import without it", not "show the dialog".
     */
    @Test
    fun aDeclinedTypeIsNotAskedForAgain() {
        val chosen = setOf(ImportType.STEPS, ImportType.TOTAL_CALORIES)
        val asked = HealthConnectImporter.requestFor(chosen)
        val granted = setOf(perm(StepsRecord::class))

        assertTrue(HealthConnectImporter.permissionsToRequest(asked, chosen, granted).isEmpty())
        assertTrue(HealthConnectImporter.anySelectedGranted(chosen, granted))
    }

    /** A newly selected type is still asked for, once, and only it: nothing already granted is asked again. */
    @Test
    fun aNewlySelectedTypeIsAskedForOnce() {
        val before = setOf(ImportType.STEPS)
        val asked = HealthConnectImporter.requestFor(before)
        val granted = setOf(perm(StepsRecord::class), HealthConnectImporter.HISTORY_PERMISSION)

        assertEquals(
            setOf(perm(ExerciseSessionRecord::class)),
            HealthConnectImporter.permissionsToRequest(asked, before + ImportType.WORKOUTS, granted),
        )
    }

    /**
     * The 2026-11-14 bug: the dialog asked only for calories, the wearer declined, and its answer (which covers
     * only what it asked) read as "nothing granted" although steps were. The import decision is taken from
     * the full grant set read afterwards, which still holds steps.
     */
    @Test
    fun declinedNewTypesDoNotCancelAnImportOfGrantedOnes() {
        val chosen = setOf(ImportType.STEPS, ImportType.ACTIVE_CALORIES)
        val dialogAnswer = emptySet<String>()
        val grantedAfterwards = setOf(perm(StepsRecord::class))

        assertFalse(HealthConnectImporter.anySelectedGranted(chosen, dialogAnswer))
        assertTrue(HealthConnectImporter.anySelectedGranted(chosen, grantedAfterwards))
    }

    @Test
    fun partialGrantReadsOnlyGrantedSelectedTypes() {
        val readable = HealthConnectImporter.readableRecordTypes(
            types = recovery + ImportType.STEPS,
            grantedPermissions = setOf(perm(HeartRateRecord::class), perm(StepsRecord::class)),
        )

        assertEquals(setOf(HeartRateRecord::class, StepsRecord::class), readable)
        assertFalse(WeightRecord::class in readable)
    }

    @Test
    fun grantForAnUnselectedTypeIsNotRead() {
        val readable = HealthConnectImporter.readableRecordTypes(
            types = recovery,
            grantedPermissions = setOf(perm(HeartRateRecord::class), perm(StepsRecord::class)),
        )

        assertEquals(setOf(HeartRateRecord::class), readable)
    }

    /**
     * #645 migration: a user who granted Health Connect before the selector existed has no stored
     * selection, and if they onboarded before #949 no permission signature either. Their Android grants
     * are the only honest record of what they agreed to, so the scope is read back off those rather than
     * defaulted. One granted type claims its whole group.
     */
    @Test
    fun grantsFromBeforeTheSelectorRecoverTheirGroups() {
        val granted = setOf(perm(HeartRateRecord::class), perm(StepsRecord::class))
        assertEquals(
            recovery + ImportCategory.STEPS.types,
            HealthConnectImporter.typesFromGrantedPermissions(granted),
        )
    }

    /** A fresh install grants nothing, so there is nothing to recover and the caller keeps its default. */
    @Test
    fun noGrantsRecoversNothing() {
        assertTrue(HealthConnectImporter.typesFromGrantedPermissions(emptySet()).isEmpty())
    }

    @Test
    fun oneGrantedTypeClaimsItsGroup() {
        assertEquals(
            body,
            HealthConnectImporter.typesFromGrantedPermissions(setOf(perm(WeightRecord::class))),
        )
    }
}
