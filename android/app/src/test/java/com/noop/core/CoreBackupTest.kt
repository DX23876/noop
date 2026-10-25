package com.noop.core

import org.junit.Assert.assertEquals
import org.junit.Test

class CoreBackupTest {
    @Test fun theCoreResultLinesParse() {
        assertEquals(CoreBackup.Result.Done, CoreBackup.parse("done"))
        assertEquals(CoreBackup.Result.Imported, CoreBackup.parse("imported"))
        assertEquals(CoreBackup.Result.TooLarge("whoop.sqlite"), CoreBackup.parse("tooLarge:whoop.sqlite"))
        assertEquals(CoreBackup.Result.Failed("foreignBackup"), CoreBackup.parse("failed:foreignBackup"))
        assertEquals(CoreBackup.Result.Failed("noCore"), CoreBackup.parse(null))
    }
}
