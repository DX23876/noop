package com.noop.ui

import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * #175 call-site census — every UI read through `repo.resolvedSeries(…)` must thread the
 * registry's ACTIVE strap id.
 *
 * The #172 bug was not in the resolver: resolvedSeries() worked, but its `strapDeviceId`
 * parameter defaulted to the canonical "my-whoop" and NO caller overrode it, so after a strap
 * re-add every resolver-backed surface (Today Rest ring, Key Metrics Rest card, Trends,
 * Health, Compare, Lab Book) silently read the wrong source pair. #175 fixed all eight call
 * sites by passing `strapDeviceId = vm.activeStrapId` — a fix a new caller can quietly regress
 * by leaning on the default again, which compiles fine and passes every behavioural test that
 * doesn't simulate a re-add.
 *
 * So this test audits the SOURCE: it scans src/main/java/com/noop/ui for `resolvedSeries(`
 * call sites (comments stripped) and fails on any call that doesn't name `strapDeviceId`.
 * The behavioural halves live in [com.noop.data.ResolvedSeriesActiveStrapTest] (threaded vs
 * default read) and [com.noop.data.ResolverUnionTest] (candidate-list shape, #1008).
 * Follows the source-locating pattern of [GermanLocalizationTest].
 */
class ResolvedSeriesCallSiteAuditTest {

    /** The UI source root, tolerant of the test host's working dir (module dir under Gradle,
     *  repo root under some IDE runners). Skips (assume) when unlocatable rather than
     *  green-washing the audit. */
    private fun uiSourceDir(): File? {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(userDir, "src/main/java/com/noop/ui"),
            File(userDir, "app/src/main/java/com/noop/ui"),
            File(userDir, "android/app/src/main/java/com/noop/ui"),
        ).firstOrNull { it.isDirectory }
    }

    /** Source text with /* block */ and // line comments removed (KDoc headers in these files
     *  mention resolvedSeries by name). `//` inside a string URL ("https://…") is preserved. */
    private fun stripComments(source: String): String {
        val noBlocks = Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL).replace(source, "")
        return noBlocks.lineSequence().joinToString("\n") { line ->
            var cut = -1
            var i = 0
            while (i < line.length - 1) {
                if (line[i] == '/' && line[i + 1] == '/' && (i == 0 || line[i - 1] != ':')) {
                    cut = i; break
                }
                i++
            }
            if (cut >= 0) line.substring(0, cut) else line
        }
    }

    /** The full argument text of each `resolvedSeries(…)` call in [source], parens balanced
     *  across lines. */
    private fun callArgTexts(source: String): List<String> {
        val calls = mutableListOf<String>()
        var searchFrom = 0
        while (true) {
            val at = source.indexOf("resolvedSeries(", searchFrom)
            if (at < 0) break
            val open = at + "resolvedSeries".length
            var depth = 0
            var end = open
            while (end < source.length) {
                when (source[end]) {
                    '(' -> depth++
                    ')' -> { depth--; if (depth == 0) break }
                }
                end++
            }
            calls.add(source.substring(open + 1, end))
            searchFrom = end
        }
        return calls
    }

    @Test
    fun everyUiResolvedSeriesCallThreadsTheActiveStrapId() {
        val dir = uiSourceDir()
        assumeTrue("com/noop/ui sources not reachable from ${System.getProperty("user.dir")}", dir != null)

        val offenders = mutableListOf<String>()
        var callCount = 0
        dir!!.walkTopDown().filter { it.isFile && it.extension == "kt" }.forEach { file ->
            for (args in callArgTexts(stripComments(file.readText()))) {
                callCount++
                if (!args.contains("strapDeviceId")) {
                    offenders.add("${file.name}: resolvedSeries(${args.trim().take(80)}…)")
                }
            }
        }

        // Scanner sanity: #175 fixed eight call sites; the scan finding fewer means the audit
        // went blind (moved sources, renamed API), not that the problem shrank. If callers were
        // legitimately consolidated behind a helper that threads the id, update this floor.
        assertTrue("expected >= 8 resolvedSeries call sites, scanned $callCount", callCount >= 8)

        assertTrue(
            "resolvedSeries callers must pass `strapDeviceId = vm.activeStrapId` (#172/#175); " +
                "leaning on the canonical default breaks every strap re-add:\n" +
                offenders.joinToString("\n"),
            offenders.isEmpty(),
        )
    }
}
