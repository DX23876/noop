package com.noop.ui

import android.content.Context
import com.noop.data.ImportSummary
import com.noop.ingest.ImportProgress
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Runs one importer, on the view model's scope, one at a time.
 *
 * Fork (DX23876), 2026-11-22. Both screens that start an import had their own copy of this, and the two
 * copies had drifted into different bugs. `DataSourcesScreen` was moved onto the view model's scope on
 * 2026-11-15 because a Health Connect import over the ten-year window takes minutes and
 * `rememberCoroutineScope` cancelled it the moment the wearer navigated away. `OnboardingScreen` kept the
 * screen's scope, which is where a new wearer starts their first import: the tester log of 2026-11-22
 * shows it dying at 195 000 records with "The coroutine scope left the composition", on the one import
 * that matters most, because leaving onboarding is the next thing anybody does.
 *
 * So there is one runner now. It also holds the single-import slot ([ImportProgress.claim]), which
 * neither copy did: the same log has nine import starts, two of them in the same second, each reading
 * its own ten-year window.
 */
internal object ImportRunner {

    /**
     * Starts [block] on the view model's scope. Returns false when another import already holds the
     * slot, so the caller can say so rather than starting a second one in silence.
     *
     * [onDone] runs on the main dispatcher once the import has finished, for whatever the calling screen
     * needs to refresh. The progress is ended in a `finally`, because an importer returns from a dozen
     * places and throws from more; ending it where it is begun is the only way every one is covered.
     */
    fun run(
        context: Context,
        vm: AppViewModel,
        onDone: suspend (ImportSummary) -> Unit = {},
        block: suspend () -> ImportSummary,
    ): Boolean {
        if (!ImportProgress.claim()) return false
        vm.viewModelScope.launch {
            val summary = withContext(Dispatchers.IO) {
                try {
                    runCatching { block() }
                        .getOrElse { ImportSummary.failure("Import", it.message ?: "failed") }
                } finally {
                    ImportProgress.end(context)
                }
            }
            // Mirror the import into the SAME exported strap log the WHOOP path uses (issue #421 parity),
            // so a tester's file import is captured in a shared debug bundle. On success: brand label +
            // per-table COUNTS only. On a zero-row/failed import: the brand label + the human reason.
            // Never a file name, a path, or any health value.
            if (summary.totalRows > 0) {
                val countsText = summary.counts.entries.joinToString(", ") { "${it.key}=${it.value}" }
                vm.ble.externalLog("Import ${summary.source}: $countsText")
            } else {
                vm.ble.externalLog("Import ${summary.source} failed: ${summary.message}")
            }
            // Import & Data Ingest test mode (Test Centre): emit the parser / per-stage / day-delta trace,
            // tagged IMPORT, iff the mode is on. Gated zero-cost when off.
            emitImportTrace(context, vm, summary)
            onDone(summary)
        }
        return true
    }
}
