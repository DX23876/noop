package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The entries are generated from `AppLanguageCatalog` in the shared core, so this no longer names
 * languages one by one: that is what let the list drift from Apple's for months without a failure.
 * `Tools/gen_app_languages.py --check` holds the list itself; these are the properties every entry
 * has to have whatever the catalogue says, plus one nail for the language that was missing.
 */
class AppLanguageTest {
    private val explicit = AppLanguage.entries.filter { it != AppLanguage.SYSTEM }

    @Test
    fun unknownOrMissingStoredLanguageFallsBackToSystem() {
        assertEquals(AppLanguage.SYSTEM, AppLanguage.fromStorage(null))
        assertEquals(AppLanguage.SYSTEM, AppLanguage.fromStorage("unsupported"))
    }

    @Test
    fun everyExplicitLanguageRoundTripsItsStableTag() {
        explicit.forEach { language ->
            assertEquals(language, AppLanguage.fromStorage(language.storageValue))
        }
    }

    @Test
    fun everyExplicitLanguageIsPickableAndNameable() {
        assertTrue("the generated list is empty", explicit.size > 1)
        explicit.forEach { language ->
            val tag = language.storageValue
            assertNotNull("${language.name} has no tag to store", tag)
            assertTrue("${language.name} has no autonym for the picker", language.autonym.isNotBlank())
            // A tag the platform cannot parse would leave the picker switching to nothing.
            assertEquals("${language.name} carries a tag the platform rereads differently",
                         tag, java.util.Locale.forLanguageTag(tag!!).toLanguageTag())
        }
    }

    @Test
    fun russianIsOffered() {
        // It was translated down to the core's own table and the picker did not list it (2026-11-22).
        val russian = AppLanguage.fromStorage("ru")
        assertEquals("Русский", russian.autonym)
    }
}
