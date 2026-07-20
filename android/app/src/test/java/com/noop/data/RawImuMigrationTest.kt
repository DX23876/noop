package com.noop.data

import com.noop.protocol.Whoop5RawImu
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * Guards the additive v20 -> v21 Room migration (the `rawImuSample` table, #423), the Android twin of the
 * Swift WhoopStore `v28-raw-imu` GRDB migration, plus the packed-BLOB encoding that must be byte-identical
 * to Swift's IMU pack for a `.noopbak` to round-trip, and the decoder's `rawColumns` extraction.
 *
 * No Robolectric Room here, so the migration SQL is pinned via [WhoopDatabase.RAW_IMU_MIGRATION_SQL] to
 * Room's generated shape; the store-write plumbing (insert + rolling prune) is exercised through a Proxy
 * [WhoopDao] (no DB).
 */
class RawImuMigrationTest {

    // MARK: - Migration schema

    @Test
    fun migration_isAdditive_onlyCreateTable() {
        val sql = WhoopDatabase.RAW_IMU_MIGRATION_SQL
        assertEquals("one CREATE TABLE statement", 1, sql.size)
        for (s in sql) {
            val up = s.trimStart().uppercase()
            assertTrue("only CREATE TABLE allowed, got: $s", up.startsWith("CREATE TABLE"))
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "ALTER ")) {
                assertTrue("additive migration must not contain '$banned': $s", !up.contains(banned))
            }
        }
    }

    @Test
    fun migration_createsExactTable() {
        // deviceId TEXT, ts INTEGER, samples BLOB — column order == entity field order, matching the GRDB
        // t.column(deviceId/ts/samples) order and PRIMARY KEY(deviceId, ts).
        assertEquals(
            listOf(
                "CREATE TABLE IF NOT EXISTS `rawImuSample` (`deviceId` TEXT NOT NULL, " +
                    "`ts` INTEGER NOT NULL, `samples` BLOB NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
            ),
            WhoopDatabase.RAW_IMU_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_versionPair_is20to21() {
        assertEquals(20, WhoopDatabase.MIGRATION_20_21.startVersion)
        assertEquals(21, WhoopDatabase.MIGRATION_20_21.endVersion)
    }

    // MARK: - Packed-BLOB encoding (byte-identical i16 LE)

    @Test
    fun packUnpackRoundTrips() {
        val cols = shortArrayOf(0, 1, -1, 32767, -32768, -1432, 12345)
        val packed = StreamPersistence.packImuColumns(cols)
        assertEquals("2 bytes/sample", cols.size * 2, packed.size)
        assertArrayEquals(cols, StreamPersistence.unpackImuColumns(packed))
    }

    @Test
    fun packIsLittleEndianI16() {
        // -1432 == 0xFA68: low byte 0x68 first, high byte 0xFA second (matches the GRDB blob bytes).
        val packed = StreamPersistence.packImuColumns(shortArrayOf(-1432))
        assertArrayEquals(byteArrayOf(0x68.toByte(), 0xFA.toByte()), packed)
    }

    @Test
    fun unpackDropsTrailingOddByte() {
        val data = StreamPersistence.packImuColumns(shortArrayOf(1, 2, 3)) + byteArrayOf(0xFF.toByte())
        assertArrayEquals(shortArrayOf(1, 2, 3), StreamPersistence.unpackImuColumns(data))
    }

    // MARK: - Decoder rawColumns extraction

    @Test
    fun rawColumns_extractsColumnarWireOrder() {
        val f = validImuBuffer()
        // Put a distinct marker at sample 0 of each of the six columns (ax,ay,az,gx,gy,gz).
        val colOff = intArrayOf(28, 228, 428, 640, 840, 1040)
        val markers = shortArrayOf(11, -22, 33, -44, 55, -66)
        for (c in colOff.indices) putI16(f, colOff[c], markers[c])
        val cols = Whoop5RawImu.rawColumns(f) ?: error("rawColumns returned null for a valid buffer")
        assertEquals(6 * 100, cols.size)
        // Column c occupies [c*100, (c+1)*100); its sample-0 sits at c*100.
        for (c in markers.indices) assertEquals("column $c sample 0", markers[c], cols[c * 100])
    }

    @Test
    fun rawColumns_nullOnWrongLengthOrCount() {
        assertNull("wrong length", Whoop5RawImu.rawColumns(ByteArray(1243)))
        val f = validImuBuffer()
        putI16(f, 24, 99)                            // countA != 100
        assertNull("wrong sample count", Whoop5RawImu.rawColumns(f))
    }

    // MARK: - Store-write plumbing (repository inserts + rolling prune through the DAO)

    @Test
    fun repositoryInsertRawImu_insertsThenPrunes() = runBlocking {
        var inserted: List<RawImuSampleEntity>? = null
        var prunedDevice: String? = null
        var prunedKeep = -1
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "insertRawImu" -> {
                    @Suppress("UNCHECKED_CAST")
                    inserted = args[0] as List<RawImuSampleEntity>
                    listOf(1L)
                }
                "pruneRawImu" -> { prunedDevice = args[0] as String; prunedKeep = args[1] as Int; Unit }
                else -> throw UnsupportedOperationException("raw-imu insert must not call ${method.name}")
            }
        } as WhoopDao

        val row = RawImuSampleEntity("my-whoop", 1_780_917_232L, StreamPersistence.packImuColumns(shortArrayOf(1, -1, 100)))
        WhoopRepository(dao).insertRawImu("my-whoop", listOf(row))

        assertEquals(listOf(row), inserted)
        assertEquals("my-whoop", prunedDevice)
        assertEquals(WhoopRepository.RAW_IMU_RETENTION_ROWS, prunedKeep)
    }

    @Test
    fun repositoryInsertRawImu_emptyIsNoOp() = runBlocking {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ -> throw AssertionError("empty insert must not touch the DAO (${method.name})") } as WhoopDao
        WhoopRepository(dao).insertRawImu("my-whoop", emptyList())
    }

    private fun validImuBuffer(): ByteArray {
        val f = ByteArray(Whoop5RawImu.bufferLength)
        putI16(f, 24, 100)   // countA
        putI16(f, 630, 100)  // countB
        return f
    }

    private fun putI16(f: ByteArray, off: Int, v: Short) {
        f[off] = (v.toInt() and 0xFF).toByte()
        f[off + 1] = ((v.toInt() shr 8) and 0xFF).toByte()
    }
}
