package com.noop.data

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Android half of the cross-platform raw-source contract. The same JSON oracle is consumed by
 * `DeviceRawSourceParityTests.swift`; adding a strap-resolution rule on one platform without its twin
 * therefore breaks one of the two native suites instead of silently changing Stress semantics.
 */
class DeviceRawSourceParityTest {
    private fun repositoryRoot(): File {
        val cwd = File(System.getProperty("user.dir") ?: ".")
        return listOf(cwd.parentFile, cwd, cwd.parentFile?.parentFile)
            .filterNotNull().firstOrNull { File(it, "android/app/src/main/java").isDirectory }
            ?: error("repository root not found from $cwd; consumer wiring guard must fail closed")
    }

    private fun production(path: String): String = File(repositoryRoot(), path).also {
        assertTrue("production source missing: $path", it.isFile)
    }.readText()

    private fun fixture(): JSONObject {
        val cwd = File(System.getProperty("user.dir") ?: ".")
        val file = listOf(
            File(cwd, "../Tools/parity_cases/device_raw_sources.json"),
            File(cwd, "Tools/parity_cases/device_raw_sources.json"),
            File(cwd, "../../Tools/parity_cases/device_raw_sources.json"),
        ).firstOrNull(File::isFile)
        assertNotNull("device_raw_sources.json not found from $cwd; parity must fail closed", file)
        return JSONObject(file!!.readText())
    }

    @Test
    fun sourceResolutionMatchesSharedOracle() {
        val cases = fixture().getJSONArray("sourceCases")
        repeat(cases.length()) { index ->
            val case = cases.getJSONObject(index)
            val active = case.getString("activeDeviceId")
            val registered = case.getJSONArray("registeredWhoopIds").let { xs ->
                List(xs.length()) { xs.getString(it) }
            }
            val imported = case.getJSONArray("imported").let { xs ->
                List(xs.length()) { xs.getString(it) }
            }
            val computed = case.getJSONArray("computed").let { xs ->
                List(xs.length()) { xs.getString(it) }
            }
            val actual = WhoopRepository.rawWhoopSourceIdsFor(active, registered)
            assertEquals(case.getString("name"), imported, actual)
            assertEquals(case.getString("name"), computed, actual.map { "$it-noop" })
        }
    }

    @Test
    fun rrIdentityMergeMatchesSharedOracle() {
        val cases = fixture().getJSONArray("rrCases")
        repeat(cases.length()) { index ->
            val case = cases.getJSONObject(index)
            val sources = case.getJSONArray("sources")
            val inputs = List(sources.length()) { sourceIndex ->
                val source = sources.getJSONObject(sourceIndex)
                val id = source.getString("id")
                val beats = source.getJSONArray("beats")
                List(beats.length()) { beatIndex ->
                    val beat = beats.getJSONObject(beatIndex)
                    RrInterval(
                        id, beat.getLong("ts"), beat.getInt("rrMs"), seq = beat.getInt("seq"),
                        ord = beat.optInt("ord").takeIf { beat.has("ord") },
                    )
                }
            }
            val actual = WhoopRepository.mergeRrByIdentity(inputs).map {
                listOf(it.ts, it.rrMs, it.seq, it.ord)
            }
            val expectedJson = case.getJSONArray("expected")
            val expected = List(expectedJson.length()) {
                expectedJson.getJSONObject(it).let { beat ->
                    listOf(
                        beat.getLong("ts"), beat.getInt("rrMs"), beat.getInt("seq"),
                        beat.optInt("ord").takeIf { beat.has("ord") },
                    )
                }
            }
            assertEquals(case.getString("name"), expected, actual)
        }
    }

    @Test
    fun aiCoachAndFullDayTimelineUseAllSourceRawFacades() {
        val coach = production("android/app/src/main/java/com/noop/ai/AiCoach.kt")
        assertTrue("AI Coach stress context must union R-R across the worn timeline", coach.contains("repo.rrIntervalsUnion("))
        assertFalse("AI Coach must not select one R-R owner", coach.contains("repo.rrIntervalsForDevice(activeStrapId()"))

        val timeline = production("android/app/src/main/java/com/noop/ui/FullDayChartScreen.kt")
        for (call in listOf("repo.hrBucketsUnion(", "repo.rrIntervalsUnion(", "repo.gravitySamplesUnion(")) {
            assertTrue("Full Day Chart must use $call", timeline.contains(call))
        }
        assertFalse("Full Day HRV must not pin R-R to the selected device", timeline.contains("repo.rrIntervalsForDevice(deviceId,"))
        assertFalse("Full Day motion must not pin gravity to the selected device", timeline.contains("repo.gravitySamplesForDevice(deviceId,"))
    }
}
