package com.noop.testcentre

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Android half of the shared feature-level raw-data collector parity guard. */
class RawDataCollectorParityTest {
    private val oracleBytes: ByteArray
        get() = requireNotNull(javaClass.classLoader!!.getResourceAsStream("raw_data_collector_parity.json"))
            .use { it.readBytes() }

    private fun repoRoot(): File {
        var cursor = File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            if (File(cursor, "android/app/src/main").isDirectory) return cursor
            cursor = cursor.parentFile ?: cursor
        }
        error("repository root not found from ${System.getProperty("user.dir")}")
    }

    @Test fun androidSurfaceStillImplementsEveryDeclaredCapability() {
        val root = repoRoot()
        val source = listOf(
            "android/app/src/main/java/com/noop/testcentre/GroundTruthCollector.kt",
            "android/app/src/main/java/com/noop/testcentre/ImuSessionFileStore.kt",
            "android/app/src/main/java/com/noop/testcentre/ImuSessionFileStore.kt",
            "android/app/src/main/java/com/noop/data/WhoopDatabase.kt",
            "android/app/src/main/java/com/noop/data/Entities.kt",
            "android/app/src/main/java/com/noop/data/WhoopRepository.kt",
            "android/app/src/main/java/com/noop/ui/GroundTruthCollectorScreen.kt",
            "android/app/src/main/java/com/noop/ble/WhoopBleClient.kt",
            "android/app/src/main/res/values/strings.xml",
        ).joinToString("\n") { File(root, it).readText() }
        val capabilities = JSONObject(oracleBytes.toString(Charsets.UTF_8)).getJSONObject("capabilities")
        for (name in capabilities.keys()) {
            val markers = capabilities.getJSONObject(name).getJSONArray("kotlin")
            for (index in 0 until markers.length()) {
                val marker = markers.getString(index)
                assertTrue("Android collector lost $name marker: $marker", source.contains(marker))
            }
        }
    }

    @Test fun androidAndAppleOracleCopiesAreByteIdentical() {
        val apple = File(repoRoot(), "StrandTests/Resources/raw_data_collector_parity.json")
        assertEquals(oracleBytes.toList(), apple.readBytes().toList())
    }
}
