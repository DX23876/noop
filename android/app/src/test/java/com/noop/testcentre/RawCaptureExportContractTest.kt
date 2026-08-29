package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class RawCaptureExportContractTest {
    private fun source(name: String): String {
        var root = File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            val file = File(root, "android/app/src/main/java/com/noop/testcentre/$name")
            if (file.isFile) return file.readText()
            root = root.parentFile ?: root
        }
        error("repository root not found")
    }

    @Test fun halfHourBucketsAreStableUtcEpochBuckets() {
        assertEquals(0, ImuSessionFileStore.bucketStart(1_799))
        assertEquals(1_800, ImuSessionFileStore.bucketStart(1_800))
        assertEquals(1_800, ImuSessionFileStore.bucketStart(3_599))
        assertEquals("19700101T003000Z", ImuSessionFileStore.utcName(1_800))
    }

    @Test fun collectorExportsCanonicalImusWithoutDerivedImuc() {
        val collector = source("GroundTruthCollector.kt")
        val store = source("ImuSessionFileStore.kt")
        assertTrue(collector.contains("exportSegments(id, sensorFrom, sensorTo)"))
        assertTrue(collector.contains("ZipEntry(\"imu/\${segment.name}\")"))
        assertTrue(store.contains("Whoop5RawImu.rawColumns(frame)"))
        assertTrue(store.contains("SEGMENT_SECONDS = 30 * 60L"))
        assertFalse(collector.contains(".imuc"))
        assertFalse(store.contains("frame.copyOf()"))
    }

    @Test fun liveCoverageUsesTimestampIndexInsteadOfDecodingPayloads() {
        val store = source("ImuSessionFileStore.kt")
        val stats = store.substringAfter("fun stats(").substringBefore("fun append(")
        assertTrue(stats.contains("timestamps(file)"))
        assertFalse(stats.contains("readRecords("))
    }

    @Test fun editedWindowOwnsPublicEventsAndImuBounds() {
        val collector = source("GroundTruthCollector.kt")
        assertTrue(collector.contains("publicEvents(events, summary.startedAtMs, endMs, deviceId)"))
        assertTrue(collector.contains("summary.markers.filter { it.atMs in summary.startedAtMs..endMs }"))
        assertTrue(collector.contains("val sensorFrom = ceilSecond(summary.startedAtMs)"))
        assertTrue(collector.contains("val sensorTo = endMs / 1_000L - 1L"))
        assertTrue(collector.contains("summary.capturedStartedAtMs != null"))
        assertTrue(collector.contains("imuSegments.minOfOrNull { it.startTs }"))
        assertTrue(collector.contains("val sensorAvailable = imuSegments.isNotEmpty() ||"))
    }

    @Test fun sessionPayloadDeletionKeepsDiscoveryFileUntilLast() {
        val collector = source("GroundTruthCollector.kt")
        assertTrue(collector.contains("if (!imuStore.deleteFiles(sessionId)) return false"))
        assertTrue(collector.contains("if (eventFile(sessionId).exists() && !eventFile(sessionId).delete()) return false"))
    }

    @Test fun rawCollectorHasNoStepAlgorithmExport() {
        val collector = source("GroundTruthCollector.kt")
        assertFalse(collector.contains("algorithm-signals.csv"))
        assertFalse(collector.contains("stepSamples("))
    }
}
