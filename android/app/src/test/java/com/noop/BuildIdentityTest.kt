package com.noop

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * The build stamp (#47): what the strap log and the screen footers say about which build they came from.
 *
 * The formatting halves take their parts rather than reading `BuildConfig`, so the stamped and the
 * unstamped shape are both covered without building two variants. The audit halves are the ones that
 * matter over time: the point of [BuildIdentity] is that a log and a screenshot of the same install
 * cannot name different builds, and counting today's call sites would pass while a fourth readout
 * composed the line for itself. So they assert the resolver is the only reader of the stamp.
 * Source-locating pattern as in [com.noop.ui.ResolvedSeriesCallSiteAuditTest].
 */
class BuildIdentityTest {

    @Test
    fun stampedBuildShowsVersionAndStamp() {
        assertEquals("13.0.0 · 7b8d2d9 2026-11-14", BuildIdentity.uiVersion("13.0.0", "7b8d2d9 2026-11-14"))
    }

    /**
     * The stamp LEADS with the channel, so a screen and a log both say which kind of build this is.
     * The numbers cannot: a testing build and the release of the same train both read "13.0.0", and
     * until 2026-11-18 every workflow stamped the bare commit and date, so an install could not be
     * told apart from a release. The word comes from the builder (`fork-testing-build.yml` stamps
     * `testing`, the release workflows `release`); this object still only prints what it is handed.
     */
    @Test
    fun theStampSaysWhetherThisIsATestingBuildOrARelease() {
        assertEquals("13.0.0 · testing 75801dc 2026-11-18",
                     BuildIdentity.uiVersion("13.0.0", "testing 75801dc 2026-11-18"))
        assertEquals("13.0.0 · release 75801dc 2026-11-18",
                     BuildIdentity.uiVersion("13.0.0", "release 75801dc 2026-11-18"))
        assertEquals(
            "App:     13.0.0 (full) build 1 · testing 75801dc 2026-11-18 · io.github.dx23876.noop",
            BuildIdentity.logLine("13.0.0", "full", 1, "io.github.dx23876.noop",
                                  "testing 75801dc 2026-11-18"),
        )
    }

    @Test
    fun unstampedBuildShowsTheVersionAlone() {
        assertEquals("13.0.0-debug", BuildIdentity.uiVersion("13.0.0-debug", null))
    }

    @Test
    fun logLineNamesVersionTierCodeStampAndApplicationId() {
        assertEquals(
            "App:     13.0.0 (full) build 1 · 7b8d2d9 2026-11-14 · io.github.dx23876.noop",
            BuildIdentity.logLine("13.0.0", "full", 1, "io.github.dx23876.noop", "7b8d2d9 2026-11-14"),
        )
    }

    /** Named, not left out: a missing field reads as "some build or other", which is the state the
     *  report in #47 arrived in. */
    @Test
    fun logLineSaysWhenThereIsNoStamp() {
        assertEquals(
            "App:     13.0.0-debug (demo) build 1 · no build stamp · io.github.dx23876.noop.demo",
            BuildIdentity.logLine("13.0.0-debug", "demo", 1, "io.github.dx23876.noop.demo", null),
        )
    }

    @Test
    fun onlyBuildIdentityReadsTheBuildStamp() {
        val files = kotlinSources() ?: return
        val readers = files.filter { it.readText().contains("BUILD_STAMP") }.map { it.name }.sorted()
        assertEquals(listOf("BuildIdentity.kt"), readers)
    }

    @Test
    fun theStrapLogHeaderAndTheForgeFootersGoThroughBuildIdentity() {
        val files = kotlinSources() ?: return
        for (name in listOf("AndroidDiagnostics.kt", "ForgeMore.kt", "ForgeSettingsAbout.kt")) {
            val file = files.firstOrNull { it.name == name }
            assertNotNull("$name is gone; whatever replaced it has to read BuildIdentity too", file)
            assertTrue("$name no longer reads BuildIdentity", file!!.readText().contains("BuildIdentity."))
        }
    }

    /** Every Kotlin file under src/main, or null (and a skipped test) when the tree is not locatable
     *  from the test host's working dir — module dir under Gradle, repo root under some IDE runners.
     *  Skipping rather than green-washing the audit. */
    private fun kotlinSources(): List<File>? {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val root = listOf(
            File(userDir, "src/main/java/com/noop"),
            File(userDir, "app/src/main/java/com/noop"),
            File(userDir, "android/app/src/main/java/com/noop"),
        ).firstOrNull { it.isDirectory }
        assumeTrue("src/main not locatable from $userDir", root != null)
        return root?.walkTopDown()?.filter { it.isFile && it.name.endsWith(".kt") }?.toList()
    }
}
