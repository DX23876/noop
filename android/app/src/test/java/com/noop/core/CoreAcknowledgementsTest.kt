package com.noop.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The wire shape of `about.acknowledgements` (the Swift side is pinned in `CoreAcknowledgementsTests`). */
class CoreAcknowledgementsTest {
    @Test fun parsesEveryPartOfTheCreditList() {
        val json = JSONObject("""{
            "content":[{"title":"MuscleMap body geometry","detail":"Used for the muscle picker.","link":"https://example.org/a"}],
            "licenses":[{"title":"GRDB.swift","detail":"SQLite layer.","link":"https://example.org/g","licenseName":"MIT",
                         "resource":"GRDB-LICENSE","fileLabel":"MIT · GRDB-LICENSE.txt"}],
            "media":{"title":"Exercise media","detail":"Not licensed."},
            "contributors":[{"handle":"@someone","work":"A fix"}],
            "attributionUrl":"https://example.org/ATTRIBUTION.md"}""")
        val credits = CoreAcknowledgements.parse(json)
        assertEquals("MuscleMap body geometry", credits.content.single().title)
        assertEquals("https://example.org/a", credits.content.single().link)
        assertEquals("GRDB-LICENSE", credits.licenses.single().resource)
        assertEquals("MIT · GRDB-LICENSE.txt", credits.licenses.single().fileLabel)
        assertNull(credits.media.link)
        assertEquals("@someone", credits.contributors.single().handle)
        assertEquals("https://example.org/ATTRIBUTION.md", credits.attributionUrl)
    }
}
