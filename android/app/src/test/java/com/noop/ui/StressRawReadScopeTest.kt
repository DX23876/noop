package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StressRawReadScopeTest {
    private fun source(): String {
        var dir: File? = File(System.getProperty("user.dir"))
        repeat(5) {
            val current = dir ?: return@repeat
            val candidate = File(current, "app/src/main/java/com/noop/ui/StressScreen.kt")
            if (candidate.isFile) return candidate.readText()
            dir = current.parentFile
        }
        error("StressScreen.kt not found from ${System.getProperty("user.dir")}")
    }

    @Test
    fun intradayAndBaselineUseDeviceAwareRawReads() {
        val text = source().replace(Regex("\\s+"), " ")
        assertTrue(text.contains("hrSamplesUnion(vm.activeStrapId"))
        assertTrue(text.contains("rrIntervalsUnion(vm.activeStrapId"))
        assertTrue(text.contains("gravitySamplesUnion(vm.activeStrapId"))
        assertFalse(Regex("(hrSamples|rrIntervals|gravitySamples)\\(\\s*\"my-whoop\"").containsMatchIn(text))
    }

    @Test
    fun storedDailyStressRemainsCanonical() {
        assertTrue(source().contains("metricSeries(\"my-whoop\", \"stress\""))
    }
}
