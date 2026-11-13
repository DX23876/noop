package com.noop.ui

import com.noop.core.CoreDeviceData
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * One WHOOP entry, Android side: runs the core's merge and reports where it is, so the Devices screen can
 * show the progress card. Fork (DX23876), twin of the Apple `AppModel.foldWhoopEntries` ordering.
 *
 * Decides nothing. Which straps exist, which one stays and which row moves where is the core's
 * (`WhoopRowFold`, through [CoreDeviceData]); what is here is the order the host has to keep, because
 * only the host can write a backup and re-point the Bluetooth link:
 *
 *  1. ask the core whether there is anything to merge
 *  2. write a full `.noopbak` first and STOP if that fails, since merging cannot be undone in the app
 *  3. bind the keeper's strap to the one WHOOP entry BEFORE any row moves
 *  4. re-target the live link, so the strap records under the surviving id while older rows still move
 *  5. run the fold a chunk at a time until the core says it is done
 *
 * Interrupting is safe at every point: each row is under exactly one id at any moment and the next run
 * continues. The runner lives on the application, not on the screen, so leaving Devices does not stop it;
 * killing the process does, and the offer comes back.
 */
class WhoopMergeRunner(
    private val core: Core,
    /** Re-point the live WHOOP link after the bind (`SourceCoordinator.retargetActiveWhoop`). */
    private val retarget: suspend () -> Unit,
    /** The in-app strap log. Rare events, so they are always recorded, not gated on Test Centre. */
    private val log: (String) -> Unit,
    /** Run once the merge finished: reload the device list and re-read the offer. */
    private val onFinished: suspend () -> Unit,
    private val chunk: Int = DEFAULT_CHUNK,
    private val now: () -> Long = System::currentTimeMillis,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    /** The core calls this runner needs; an interface so the order is testable without a core. */
    interface Core {
        fun offer(): CoreDeviceData.MergeOffer?
        fun bind(identityFrom: String?): Boolean
        fun step(identityFrom: String?, chunk: Int): CoreDeviceData.MergeStep?
    }

    /** The safety copy. The folder destination and the one the wearer picks both write a `.noopbak`
     *  through the core, so this only answers with the name it wrote, or null when it wrote nothing. */
    interface Backup {
        fun write(name: String): String?
    }

    /** Why a merge did not start or did not finish. The screen turns these into its own sentences; no
     *  wearer-facing text lives in here. */
    enum class Failure { BACKUP, CORE }

    sealed interface State {
        data object Idle : State
        /** Rows moved so far. */
        data class Working(val moved: Int) : State
        data class Failed(val why: Failure) : State
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    /** The name of the safety copy a run is about to write, so the picker offers the same one. */
    fun backupName(): String = BackupSync.mergeBackupName(now())

    /**
     * Start a merge. A second call while one runs is ignored, so two loops never work on one store.
     * [backup] has to write the file before anything moves.
     */
    fun start(backup: Backup) {
        if (_state.value is State.Working) return
        _state.value = State.Working(0)
        scope.launch { merge(backup) }
    }

    private suspend fun merge(backup: Backup) {
        val offer = core.offer()
        if (offer == null) {
            _state.value = State.Failed(Failure.CORE)
            log("One WHOOP: the merge could not read your entries; nothing was combined")
            return
        }
        if (!offer.needed) {
            _state.value = State.Idle
            onFinished()
            return
        }
        val written = backup.write(backupName())
        if (written == null) {
            _state.value = State.Failed(Failure.BACKUP)
            log("One WHOOP: the safety backup failed; nothing was combined")
            return
        }
        log("One WHOOP: safety backup written ($written); combining the extra WHOOP entries into the " +
            "WHOOP entry${offer.keeperName?.let { ", $it stays connected" } ?: ""}")
        if (!core.bind(offer.identityFrom)) {
            _state.value = State.Failed(Failure.CORE)
            log("One WHOOP: could not bind the WHOOP entry; nothing moved")
            return
        }
        // Before the first row moves: the strap keeps recording, under the id that survives.
        retarget()
        val started = now()
        var moved = 0
        while (true) {
            val step = core.step(offer.identityFrom, chunk)
            if (step == null) {
                _state.value = State.Failed(Failure.CORE)
                log("One WHOOP: combining stopped after $moved readings; it continues the next time")
                return
            }
            moved += step.moved
            _state.value = State.Working(moved)
            if (step.done) break
        }
        log("One WHOOP: combined $moved readings in ${(now() - started) / 1000} s")
        _state.value = State.Idle
        onFinished()
    }

    companion object {
        /** Rows per transaction, the core's own `WhoopRowFold.defaultChunkSize`. */
        const val DEFAULT_CHUNK = 20_000

        /** The runner the app uses: the real core calls. */
        val coreCalls: Core = object : Core {
            override fun offer() = CoreDeviceData.mergeOffer()
            override fun bind(identityFrom: String?) = CoreDeviceData.mergeBind(identityFrom)
            override fun step(identityFrom: String?, chunk: Int) = CoreDeviceData.mergeStep(identityFrom, chunk)
        }
    }
}
