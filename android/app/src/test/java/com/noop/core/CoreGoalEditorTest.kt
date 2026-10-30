package com.noop.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The goal editor arrives as the core judges it (`CoreGoalEditor.swift`, iOS's `CoachGoalEditorView`). */
class CoreGoalEditorTest {
    @Test
    fun editorStateParses() {
        val s = CoreGoalEditor.parse(JSONObject("""
            {"found":true,"draft":{"kind":"run","title":"5k","baseline":"3","target":"5","hasTargetDate":true,
              "targetDateTouched":true,"targetDate":1800000000,"motivation":"","tags":["health"],"share":false,"reason":""},
             "kinds":[{"id":"run","label":"Run","blurb":"Distance","quantified":true,"unit":"km","placeholder":"e.g."}],
             "tags":[{"id":"health","label":"Health"}],"kindNote":null,"quantified":true,"placeholder":"e.g.",
             "rangeIsUsable":true,"canSave":true,"warning":"That's brisk","veryAggressive":false,"needsReason":false,
             "volumeWarning":null,"limit":"kind","replaceId":"x","hasRoom":true,"limitText":"Replace?","saved":false,
             "labels":{"title":"Edit goal"}}
        """.trimIndent()))
        assertTrue(s.found && s.canSave && s.quantified)
        assertEquals(listOf("health"), s.draft.tags)
        assertEquals(1_800_000_000.0, s.draft.targetDate, 0.0)
        assertEquals("That's brisk", s.warning)
        assertNull(s.volumeWarning)
        assertNull(s.kindNote)
        assertEquals("kind", s.limit)
        assertFalse(s.saved)
        assertEquals("Edit goal", s.labels["title"])
    }
}
