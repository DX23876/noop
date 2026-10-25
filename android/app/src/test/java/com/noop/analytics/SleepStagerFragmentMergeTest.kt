package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests SleepStager's conservative fragment-merge / hypnogram smoothing (#274). The WHOOP
 * 5/MG banks sparse motion, so the stager emits lots of sub-minute stage flecks and the
 * hypnogram reads choppier than WHOOP's. mergeFragments absorbs runs below the 3-min
 * (6-epoch) threshold into their neighbours WITHOUT erasing genuine multi-minute
 * transitions, biasing toward the lighter stage so it never inflates deep/REM.
 *
 * Faithful Kotlin mirror of the fragment-merge cases in SleepStagerTests.swift; same
 * threshold, same scenarios, same expected runs.
 */
class SleepStagerFragmentMergeTest {

    /** Expand a list of (stage, epochs) runs into a flat per-epoch label list. */
    private fun expand(runs: List<Pair<String, Int>>): List<String> {
        val out = ArrayList<String>()
        for ((s, n) in runs) repeat(n) { out.add(s) }
        return out
    }

    /** Collapse a flat label list back into (stage, epochs) runs for terse assertions. */
    private fun runs(labels: List<String>): List<Pair<String, Int>> {
        val out = ArrayList<Pair<String, Int>>()
        for (s in labels) {
            val last = out.lastOrNull()
            if (last != null && last.first == s) out[out.size - 1] = last.first to (last.second + 1)
            else out.add(s to 1)
        }
        return out
    }

    private fun assertRuns(labels: List<String>, expected: List<Pair<String, Int>>, msg: String) {
        assertEquals("$msg run list — got ${runs(labels)}", expected, runs(labels))
    }

    @Test
    fun mergeFragmentsAbsorbsSameStageBridge() {
        // A 2-epoch "deep" fleck (< 6-epoch threshold) bridged by light on both sides is
        // absorbed: the choppy light→deep→light blip becomes one continuous light block.
        val input = expand(listOf("light" to 8, "deep" to 2, "light" to 8))
        val out = SleepStager.mergeFragments(input)
        assertEquals("length preserved", input.size, out.size)
        assertRuns(out, listOf("light" to 18), "same-stage bridge")
    }

    @Test
    fun mergeFragmentsPreservesGenuineTransition() {
        // Three real multi-minute blocks (each ≥ 6 epochs = 3 min) — a genuine cycle, not
        // noise — pass through completely untouched.
        val input = expand(listOf("light" to 10, "deep" to 10, "rem" to 10))
        val out = SleepStager.mergeFragments(input)
        assertRuns(out, listOf("light" to 10, "deep" to 10, "rem" to 10), "genuine transition")
    }

    @Test
    fun mergeFragmentsBiasesLighterOnTie() {
        // A 3-epoch "deep" fleck between equal-length light and rem neighbours (8 vs 8) is a
        // tie; the lighter stage (light, rank 1 < rem rank 2) wins so smoothing never inflates
        // deep/REM. The deep fleck must NOT survive and must NOT become rem.
        val input = expand(listOf("light" to 8, "deep" to 3, "rem" to 8))
        val out = SleepStager.mergeFragments(input)
        assertRuns(out, listOf("light" to 11, "rem" to 8), "tie → lighter neighbour")
        assertFalse("a stray deep fleck must not survive a tie merge", out.contains("deep"))
    }

    @Test
    fun mergeFragmentsFoldsIntoLongerNeighbour() {
        // A short rem fleck (2) with a longer light neighbour (8) on one side and a short deep
        // run (4, itself sub-threshold) on the other collapses entirely into light — the longer
        // neighbour dominates and the trailing short deep folds back too. No deep/REM inflation.
        val input = expand(listOf("light" to 8, "rem" to 2, "deep" to 4))
        val out = SleepStager.mergeFragments(input)
        assertRuns(out, listOf("light" to 14), "fold into longer neighbour")
    }

    @Test
    fun mergeFragmentsLeadingAndTrailingFlecks() {
        // A leading deep fleck folds forward into light; a trailing rem fleck folds back into
        // light. Edge runs with only one neighbour are still smoothed.
        val input = expand(listOf("deep" to 2, "light" to 10, "rem" to 2))
        val out = SleepStager.mergeFragments(input)
        assertRuns(out, listOf("light" to 14), "leading + trailing flecks")
    }

    @Test
    fun mergeFragmentsThresholdConstant() {
        // The threshold is the named 3-min constant, i.e. 6 epochs at 30 s.
        assertEquals(6, SleepStager.fragmentMergeEpochs)
        // A run exactly AT the threshold (6 epochs) is a real transition and is preserved.
        val input = expand(listOf("light" to 10, "deep" to 6, "light" to 10))
        val out = SleepStager.mergeFragments(input)
        assertRuns(out, listOf("light" to 10, "deep" to 6, "light" to 10), "at-threshold run kept")
    }

    @Test
    fun mergeFragmentsDegenerateInputs() {
        // Empty and single-run inputs pass through unchanged (nothing to merge into).
        assertTrue(SleepStager.mergeFragments(emptyList()).isEmpty())
        val single = expand(listOf("light" to 3)) // sub-threshold but no neighbours
        assertRuns(SleepStager.mergeFragments(single), listOf("light" to 3), "single run kept")
    }
}
