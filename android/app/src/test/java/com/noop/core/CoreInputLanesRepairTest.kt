package com.noop.core

import android.content.Context
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.IOException

/**
 * A lane repair restages Room's rows with `replace` over the core's lanes. After a `.noopbak` restore Room holds
 * the pre-restore rows, so a repair still waiting, or one a later mirror failure marks before the restart, would
 * write them over the restored lanes.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE, application = android.app.Application::class)
class CoreInputLanesRepairTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @After fun tearDown() {
        CoreInputLanes.resetRestoreForTest()
        context.getSharedPreferences("forge", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test fun aMirrorFailureMarksARepair() {
        CoreInputLanes.noteMirrorFailure(context, "workout", IOException("x"))
        assertTrue(CoreInputLanes.repairPending(context))
    }

    @Test fun aRestoreForgetsTheWaitingRepairAndKeepsLaterFailuresFromMarkingOne() {
        CoreInputLanes.noteMirrorFailure(context, "workout", IOException("before"))
        assertTrue(CoreInputLanes.repairPending(context))
        CoreInputLanes.forgetRepairAfterRestore(context)
        assertFalse(CoreInputLanes.repairPending(context))
        CoreInputLanes.noteMirrorFailure(context, "sleepSession", IOException("after"))
        assertFalse("the restored store opens on restart; Room's old rows must not be restaged over it",
                    CoreInputLanes.repairPending(context))
        assertFalse(CoreInputLanes.ready)
    }

    @Test fun aRepairPassKeepsTheMarkWhenAMirrorFailedWhileItStaged() {
        val seen = CoreInputLanes.failureCount()
        assertTrue(CoreInputLanes.mayClearRepair(seen))
        CoreInputLanes.noteMirrorFailure(context, "dailyMetric", IOException("during"))
        assertFalse("a failure during the pass may concern a write its snapshot missed",
                    CoreInputLanes.mayClearRepair(seen))
        assertTrue(CoreInputLanes.mayClearRepair(CoreInputLanes.failureCount()))
    }
}
