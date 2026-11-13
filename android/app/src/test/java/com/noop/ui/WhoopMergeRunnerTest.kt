package com.noop.ui

import com.noop.core.CoreDeviceData
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.first
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * One WHOOP entry: the ORDER the host has to keep around the core's merge. Nothing is merged before a
 * full backup is on disk, the keeper's strap is bound before the first row moves, and the live link is
 * re-pointed between the two — a step that writes under an id being emptied is exactly what this order
 * exists to prevent. The merge itself is the core's and is tested there (`WhoopRowFoldTests`,
 * `CoreWhoopMergeTests`).
 */
class WhoopMergeRunnerTest {

    /** Records every call in order, so the assertions are about the sequence, not just the outcome. */
    private class FakeCore(
        private val offer: CoreDeviceData.MergeOffer?,
        private val steps: List<CoreDeviceData.MergeStep?>,
        val calls: MutableList<String> = mutableListOf(),
    ) : WhoopMergeRunner.Core {
        var bindAnswer = true
        private var next = 0
        override fun offer(): CoreDeviceData.MergeOffer? {
            calls += "offer"
            return offer
        }
        override fun bind(identityFrom: String?): Boolean {
            calls += "bind:$identityFrom"
            return bindAnswer
        }
        override fun step(identityFrom: String?, chunk: Int): CoreDeviceData.MergeStep? {
            calls += "step"
            return steps.getOrNull(next++)
        }
    }

    private val offer = CoreDeviceData.MergeOffer(needed = true, keeperId = "whoop-AA11",
                                                  keeperName = "Old strap", identityFrom = "whoop-AA11")

    private fun runner(core: WhoopMergeRunner.Core, calls: MutableList<String>,
                       log: MutableList<String> = mutableListOf()) =
        WhoopMergeRunner(
            core = core,
            retarget = { calls += "retarget" },
            log = { log += it },
            onFinished = { calls += "finished" },
            chunk = 2,
            now = { 1_762_000_000_000L },
            scope = CoroutineScope(Dispatchers.Unconfined),
        )

    private fun backup(answer: String?, calls: MutableList<String>) = object : WhoopMergeRunner.Backup {
        override fun write(name: String): String? {
            calls += "backup:$name"
            return answer
        }
    }

    private suspend fun WhoopMergeRunner.settle(): WhoopMergeRunner.State =
        withTimeout(5_000) { state.first { it !is WhoopMergeRunner.State.Working } }

    @Test
    fun backupFirstThenBindThenRetargetThenTheChunks() = runBlocking {
        val calls = mutableListOf<String>()
        val log = mutableListOf<String>()
        val core = FakeCore(offer, listOf(CoreDeviceData.MergeStep(2, false),
                                          CoreDeviceData.MergeStep(1, false),
                                          CoreDeviceData.MergeStep(0, true)), calls)
        val runner = runner(core, calls, log)
        runner.start(backup("noop-before-merge-20261101-120000.noopbak", calls))
        assertEquals(WhoopMergeRunner.State.Idle, runner.settle())
        assertEquals(
            listOf("offer", "backup:" + runner.backupName(), "bind:whoop-AA11", "retarget",
                   "step", "step", "step", "finished"),
            calls,
        )
        // The strap log carries the rare event: the backup that was written and what was combined.
        assertTrue(log.any { it.contains("safety backup written") && it.contains("Old strap") })
        assertTrue(log.any { it.contains("combined 3 readings") })
    }

    @Test
    fun aFailedBackupMovesNothing() = runBlocking {
        val calls = mutableListOf<String>()
        val log = mutableListOf<String>()
        val core = FakeCore(offer, listOf(CoreDeviceData.MergeStep(2, true)), calls)
        val runner = runner(core, calls, log)
        runner.start(backup(null, calls))
        assertEquals(WhoopMergeRunner.State.Failed(WhoopMergeRunner.Failure.BACKUP), runner.settle())
        assertEquals(listOf("offer", "backup:" + runner.backupName()), calls)
        assertFalse(calls.any { it.startsWith("bind") || it == "step" || it == "retarget" })
        assertTrue(log.any { it.contains("safety backup failed") })
    }

    @Test
    fun aRefusedBindMovesNothing() = runBlocking {
        val calls = mutableListOf<String>()
        val core = FakeCore(offer, listOf(CoreDeviceData.MergeStep(2, true)), calls)
        core.bindAnswer = false
        val runner = runner(core, calls)
        runner.start(backup("a.noopbak", calls))
        assertEquals(WhoopMergeRunner.State.Failed(WhoopMergeRunner.Failure.CORE), runner.settle())
        assertFalse(calls.contains("step"))
        assertFalse(calls.contains("retarget"))
    }

    @Test
    fun aStepThatFailsStopsTheLoopAndKeepsWhatMoved() = runBlocking {
        val calls = mutableListOf<String>()
        val log = mutableListOf<String>()
        val core = FakeCore(offer, listOf(CoreDeviceData.MergeStep(2, false), null), calls)
        val runner = runner(core, calls, log)
        runner.start(backup("a.noopbak", calls))
        assertEquals(WhoopMergeRunner.State.Failed(WhoopMergeRunner.Failure.CORE), runner.settle())
        assertEquals(2, calls.count { it == "step" })
        assertFalse(calls.contains("finished"))
        assertTrue(log.any { it.contains("stopped after 2 readings") && it.contains("continues") })
    }

    @Test
    fun nothingToMergeIsNotAFailure() = runBlocking {
        val calls = mutableListOf<String>()
        val core = FakeCore(CoreDeviceData.MergeOffer(false, null, null, null), emptyList(), calls)
        val runner = runner(core, calls)
        runner.start(backup("a.noopbak", calls))
        assertEquals(WhoopMergeRunner.State.Idle, runner.settle())
        assertEquals(listOf("offer", "finished"), calls)
    }

    @Test
    fun withoutACoreThereIsNothingToMerge() = runBlocking {
        val calls = mutableListOf<String>()
        val core = FakeCore(null, emptyList(), calls)
        val runner = runner(core, calls)
        runner.start(backup("a.noopbak", calls))
        assertEquals(WhoopMergeRunner.State.Failed(WhoopMergeRunner.Failure.CORE), runner.settle())
        assertEquals(listOf("offer"), calls)
    }

    /** The safety copy is never a snapshot the rotation prunes, but it is still a backup to restore. */
    @Test
    fun theSafetyCopyIsNotAPruneCandidate() {
        val name = BackupSync.mergeBackupName(1_762_000_000_000L)
        assertFalse(BackupSync.isSnapshot(name))
        assertTrue(BackupSync.isBackupFile(name))
        assertEquals(emptyList<String>(), BackupSync.snapshotsToPrune(listOf(name), keep = 0))
    }
}
