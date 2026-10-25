package com.noop.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Fork (DX23876): NOOP Forge's releases carry the iOS build and only sometimes an APK, so the update check
 * must name the newest release this app can install, not the newest release.
 */
class ForkUpdateCheckTest {
    private fun release(tag: String, assets: List<String>, draft: Boolean = false, prerelease: Boolean = false) =
        """{"tag_name":"$tag","html_url":"https://github.com/DX23876/noop/releases/tag/$tag",""" +
            """"draft":$draft,"prerelease":$prerelease,"assets":[${assets.joinToString(",") { """{"name":"$it"}""" }}]}"""

    @Test
    fun theNewestReleaseWithAnApkWinsOverNewerIosOnlyReleases() {
        val body = "[" + listOf(
            release("v12.3.1-dx", listOf("NOOP-Forge-12.3.1.ipa")),
            release("v12.3.0-dx", listOf("NOOP-Forge-12.3.0.ipa", "NOOP-Forge-android-12.3.0.apk")),
            release("v12.2.1-dx", listOf("NOOP-Forge-android-12.2.1.apk")),
        ).joinToString(",") + "]"
        assertEquals("v12.3.0-dx", UpdateCheck.latestWithApk(body)?.getString("tag_name"))
    }

    @Test
    fun draftsAndPrereleasesAreSkipped() {
        val body = "[" + listOf(
            release("v12.4.0-dx", listOf("a.apk"), draft = true),
            release("v12.3.9-dx", listOf("a.apk"), prerelease = true),
            release("v12.3.0-dx", listOf("a.apk")),
        ).joinToString(",") + "]"
        assertEquals("v12.3.0-dx", UpdateCheck.latestWithApk(body)?.getString("tag_name"))
    }

    @Test
    fun noApkAnywhereOrAnUnexpectedBodyGivesNothing() {
        assertNull(UpdateCheck.latestWithApk("[" + release("v12.2.1-dx", listOf("x.ipa")) + "]"))
        assertNull(UpdateCheck.latestWithApk("""{"message":"rate limited"}"""))
        assertNull(UpdateCheck.latestWithApk("not json"))
    }

    @Test
    fun theForkTagSuffixReadsAsTheSameVersion() {
        assertFalse(UpdateCheck.isNewer("12.2.1-dx", "12.2.1"))
    }
}
