package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Architecture guard for the split between the canonical WHOOP history namespace and physical
 * sensor ownership.
 *
 * `"my-whoop"` is a valid, stable source for imported/daily series. It is not, however, the id of
 * every physical strap: a re-paired or second strap banks HR, R-R and accelerometer samples under
 * `whoop-<id>`. A production UI call that passes the canonical literal to a raw-sensor API therefore
 * silently drops those samples. Stress exposed this failure as a missing intraday chart.
 *
 * This deliberately narrow source audit bans only that invalid combination. Dynamic owner reads
 * (session detail and diagnostics) remain legal, as do canonical `metricSeries` and import uses.
 * Device-aware repository methods are also legal because their first argument is an active/owning
 * device id and the repository performs the canonical union.
 */
class RawSensorDeviceScopeAuditTest {

    private fun uiSourceDir(): File {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val found = listOf(
            File(userDir, "src/main/java/com/noop/ui"),
            File(userDir, "app/src/main/java/com/noop/ui"),
            File(userDir, "android/app/src/main/java/com/noop/ui"),
        ).firstOrNull { it.isDirectory }
        assertNotNull(
            "com/noop/ui not found from user.dir=$userDir; a source guard must fail closed",
            found,
        )
        return found!!
    }

    private fun repositorySource(): String {
        val javaRoot = uiSourceDir().parentFile
        val repository = File(javaRoot, "data/WhoopRepository.kt")
        assertTrue("WhoopRepository.kt not found", repository.isFile)
        return stripComments(repository.readText())
    }

    /** Removes comments so examples and migration notes do not count as production calls. */
    private fun stripComments(source: String): String {
        val withoutBlocks = Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL).replace(source, "")
        return withoutBlocks.lineSequence().joinToString("\n") { line ->
            var quoted = false
            var escaped = false
            var cut = -1
            var index = 0
            while (index < line.length - 1) {
                val char = line[index]
                if (char == '"' && !escaped) quoted = !quoted
                if (!quoted && char == '/' && line[index + 1] == '/') {
                    cut = index
                    break
                }
                escaped = char == '\\' && !escaped
                if (char != '\\') escaped = false
                index++
            }
            if (cut >= 0) line.substring(0, cut) else line
        }
    }

    private val directRawRead = Regex("""\b(hrSamples(?:ForDevice)?|rrIntervals(?:ForDevice)?|gravitySamples(?:ForDevice)?)\s*\(""")

    private data class RawCall(val method: String, val args: String, val offset: Int)

    /** Extract raw calls with balanced parentheses so named arguments can appear in any order. */
    private fun rawCalls(source: String): List<RawCall> {
        val clean = stripComments(source)
        val calls = mutableListOf<RawCall>()
        directRawRead.findAll(clean).forEach { match ->
            val open = clean.indexOf('(', match.range.first)
            var depth = 1
            var quoted = false
            var escaped = false
            var end = open + 1
            while (end < clean.length && depth > 0) {
                val char = clean[end]
                if (char == '"' && !escaped) quoted = !quoted
                if (!quoted) {
                    if (char == '(') depth++
                    if (char == ')') depth--
                }
                escaped = char == '\\' && !escaped
                if (char != '\\') escaped = false
                end++
            }
            if (depth == 0) {
                calls += RawCall(
                    method = match.groupValues[1],
                    args = clean.substring(open + 1, end - 1),
                    offset = match.range.first,
                )
            }
        }
        return calls
    }

    private fun offenders(source: String): List<RawCall> = rawCalls(source).filter { call ->
        call.args.trimStart().startsWith("\"my-whoop\"") ||
            Regex("""\bdeviceId\s*=\s*"my-whoop"""").containsMatchIn(call.args)
    }

    @Test
    fun scannerRejectsCanonicalRawReadsButAllowsCanonicalMetricsAndDeviceAwareReads() {
        assertTrue(offenders("repo.hrSamples(\"my-whoop\", from, to)").isNotEmpty())
        assertTrue(offenders("repo.rrIntervals(\n deviceId = \"my-whoop\", from, to)").isNotEmpty())
        assertTrue(offenders("repo.gravitySamples(  \"my-whoop\", from, to)").isNotEmpty())
        assertTrue(offenders("repo.hrSamplesForDevice(\"my-whoop\", from, to)").isNotEmpty())
        assertTrue(
            offenders(
                "repo.hrSamples(from = from, to = to, limit = 5, deviceId = \"my-whoop\")",
            ).isNotEmpty(),
        )

        assertTrue(offenders("repo.metricSeries(\"my-whoop\", \"stress\", from, to)").isEmpty())
        assertTrue(offenders("repo.hrSamplesUnion(activeStrapId, from, to)").isEmpty())
        assertTrue(offenders("repo.rrIntervals(session.deviceId, from, to)").isEmpty())
        assertTrue(offenders("// repo.hrSamples(\"my-whoop\", from, to)").isEmpty())
        assertTrue(offenders("/* repo.gravitySamples(\"my-whoop\", from, to) */").isEmpty())
    }

    @Test
    fun repositoryHasNoAmbiguousDeviceScopedRawReaderNames() {
        val source = repositorySource()
        for (oldName in listOf("hrSamples", "hrBuckets", "rrIntervals", "gravitySamples", "sleepSessions")) {
            assertFalse(
                "Device-scoped repository reads must say ForDevice; ambiguous $oldName can be misused by UI",
                Regex("""suspend\s+fun\s+$oldName\s*\(""").containsMatchIn(source),
            )
        }
        for (explicitName in listOf(
            "hrSamplesForDevice", "hrBucketsForDevice", "rrIntervalsForDevice",
            "gravitySamplesForDevice", "sleepSessionsForDevice",
        )) {
            assertTrue("Missing explicit repository API $explicitName", source.contains("fun $explicitName("))
        }
    }

    @Test
    fun productionUiNeverPinsRawSensorReadsToCanonicalWhoop() {
        val violations = mutableListOf<String>()
        uiSourceDir().walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .forEach { file ->
                val source = file.readText()
                offenders(source).forEach { call ->
                    val line = stripComments(source).take(call.offset).count { it == '\n' } + 1
                    violations += "${file.name}:$line: ${call.method}(${call.args.trim().take(80)})"
                }
            }

        assertFalse(
            "Raw HR/R-R/gravity UI reads must use an owning device or a device-aware repository API; " +
                "`my-whoop` is only the canonical history/import namespace:\n" +
                violations.joinToString("\n"),
            violations.isNotEmpty(),
        )
    }

    @Test
    fun stressUsesAllThreeDeviceAwareRawTimelines() {
        val stress = File(uiSourceDir(), "StressScreen.kt")
        assertTrue("StressScreen.kt not found", stress.isFile)
        val source = stripComments(stress.readText())

        val bypasses = directRawRead.findAll(source).map { it.value }.toList()
        assertTrue(
            "Stress must not select a raw device id itself; use the repository unions: $bypasses",
            bypasses.isEmpty(),
        )
        for (api in listOf("hrSamplesUnion(", "rrIntervalsUnion(", "gravitySamplesUnion(")) {
            assertTrue("Stress must read through $api", source.contains(api))
        }
    }

    @Test
    fun coachStressAndFullDayChartUseDeviceAwareRawTimelines() {
        val javaRoot = uiSourceDir().parentFile
        val coach = File(javaRoot, "ai/AiCoach.kt")
        val chart = File(uiSourceDir(), "FullDayChartScreen.kt")
        assertTrue("AiCoach.kt not found", coach.isFile)
        assertTrue("FullDayChartScreen.kt not found", chart.isFile)

        val coachSource = stripComments(coach.readText())
        assertTrue(
            "AI Coach derived stress must include archived strap R-R history",
            coachSource.contains("repo.rrIntervalsUnion(activeStrapId()"),
        )
        assertFalse(
            "AI Coach derived stress must not bypass the device-aware R-R resolver",
            coachSource.contains("repo.rrIntervalsForDevice(activeStrapId()"),
        )

        val chartSource = stripComments(chart.readText())
        for (api in listOf("hrSamplesUnion(", "hrBucketsUnion(", "rrIntervalsUnion(", "gravitySamplesUnion(")) {
            assertTrue("Full-day chart must read through $api", chartSource.contains(api))
        }
        assertFalse(chartSource.contains("repo.rrIntervalsForDevice(deviceId"))
        assertFalse(chartSource.contains("repo.gravitySamplesForDevice(deviceId"))
    }
}
