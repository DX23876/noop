package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fork (DX23876), Android without Room: the classic backup screens go through the core (`CoreBackup`), and these are
 * the sentences they show for the core's result codes. The archive checks themselves are the Swift `BackupArchive`'s
 * and are tested there (`BackupArchiveTests`).
 */
class DataBackupFacadeTest {
    @Test
    fun theRestoreCeilingIsTheCoresFiveGibibytes() {
        assertEquals(5L * 1024 * 1024 * 1024, DataBackup.MAX_BACKUP_SQLITE_BYTES)
    }

    @Test
    fun aRoomBackupIsNoLongerForeignButOtherFilesStillAre() {
        // The core converts a Room backup, so "foreignBackup" now only reaches here for another app's database.
        assertTrue(DataBackup.importFailure("foreignBackup").startsWith("That file is not a NOOP backup"))
        assertTrue(DataBackup.importFailure("damaged").startsWith("This backup file is damaged"))
        assertEquals("The backup archive doesn't contain a database file.", DataBackup.importFailure("noDatabaseEntry"))
    }

    @Test
    fun anUnknownCodeIsShownRatherThanHidden() {
        assertEquals("Import failed, your data is unchanged: copyFailedKept:disk",
                     DataBackup.importFailure("copyFailedKept:disk"))
        assertEquals("Couldn't export: write:disk full", DataBackup.exportFailure("write:disk full"))
    }
}
