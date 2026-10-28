package com.noop.core

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.noop.protocol.Crc
import com.noop.protocol.PacketType
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.After
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Replays strap notifications through the JNI path in an installed APK, with no Bluetooth hardware. */
@RunWith(AndroidJUnit4::class)
class CoreStrapReplayTest {
    private var testFiles: File? = null

    @After
    fun removeReplayFiles() {
        testFiles?.deleteRecursively()
    }

    @Test
    fun bondedEventAndHistoryReachThePackagedCore() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // Use the real resource installer and session startup with a fresh files directory. Replaying twice
        // against the app's existing store would legitimately insert no new motion and hide test isolation bugs.
        val files = File(context.cacheDir, "core-replay-${UUID.randomUUID()}").apply { mkdirs() }
        testFiles = files
        val isolated = object : ContextWrapper(context) { override fun getFilesDir(): File = files }
        assertTrue("the test APK must include the shared core", SwiftCore.available)
        CoreShadow.ensureStarted(isolated, "protocol-replay")
        assertTrue("the packaged core must open its store", CoreShadow.running)
        CoreShadow.family(whoop5 = false)
        // The first notification after a confirmed bond exercises the schema loader that crashed on Pixel.
        CoreShadow.liveFrame(frame(type = PacketType.EVENT.rawValue, cmd = 23, data = byteArrayOf()))
        val liveTime = System.currentTimeMillis() / 1000 - 120
        CoreShadow.liveFrame(realtime(liveTime, 72))
        val rejected = realtime(liveTime + 60, 198).apply {
            this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte()
        }
        CoreShadow.liveFrame(rejected)
        CoreShadow.flush()
        CoreShadow.offloadBegin(continuedAfterRows = false)
        records.forEach { CoreShadow.offloadFrame(hex(it)) }
        val payload = le32(1_700_000_000) + byteArrayOf(0, 0) + le32(0) + le32(70_476)
        val end = frame(type = PacketType.METADATA.rawValue, cmd = 2, data = payload)
        CoreShadow.offloadFrame(end)
        // Match Backfiller.endData: the exact eight bytes the Kotlin ack gate receives, not all metadata.
        val endData = end.copyOfRange(17, 25)
        assertTrue("the replayed history must be persisted before it can be acknowledged",
            CoreShadow.awaitBanked(endData, 5_000))
        assertTrue("the real records must leave motion in the core store",
            Regex("gravity=[1-9][0-9]*").containsMatchIn(CoreShadow.tally().orEmpty()))
        val trace = CoreRead.heartRate(liveTime - 300, liveTime + 300)
        assertTrue("the live notification must be decoded and persisted", trace.isNotEmpty())
        assertTrue("the corrupt notification must not enter the live trace", trace.all { it.bpm == 72.0 })
    }

    private fun frame(type: Int, cmd: Int, data: ByteArray): ByteArray {
        val inner = byteArrayOf(type.toByte(), 0, cmd.toByte()) + data
        val length = inner.size + 4
        val lengthBytes = byteArrayOf(length.toByte(), (length ushr 8).toByte())
        return byteArrayOf(0xAA.toByte()) + lengthBytes + byteArrayOf(Crc.crc8(lengthBytes).toByte()) +
            inner + le32(Crc.crc32(inner))
    }

    private fun le32(value: Long): ByteArray = ByteArray(4) { (value ushr (it * 8)).toByte() }
    private fun realtime(ts: Long, bpm: Int): ByteArray = frame(PacketType.REALTIME_DATA.rawValue,
        (ts and 0xFF).toInt(), le32(ts).copyOfRange(1, 4) + byteArrayOf(0, 0, bpm.toByte(), 0))
    private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // Captured WHOOP 4.0 history, also replayed by NoopCoreJNI's ShadowSessionTests.
    private val records = listOf(
        "aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44",
        "aa50000c2f190014390000150d2b6a487001003ab301008dfd6afdaffda9fdaffd68fddbfb0dfc09fd77fe89fe62febffec9fe91ff0bff81ff5fff3e00d600790078ff3dff4bff801d553c5005010000d7c016b3",
        "aa50000c2f190015390000160d2b6a586b01006d8f0100a3ff94ffc4ffbcffbeff22004a009400cb0048005d006b004400d700130115013301f20088001d0031ffd9fe5eff75ff0048933c50050001008bdf2c2c",
    )
}
