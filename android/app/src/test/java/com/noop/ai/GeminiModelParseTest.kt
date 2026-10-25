package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #400: the Gemini `/v1beta/models` list parse. Gemini returns `{"models":[{"name":"models/…"}]}`
 * (unlike every other provider's OpenAI-shaped `{"data":[{"id":…}]}`), so it has its own pure parse.
 * Byte-parity REFERENCE for the Swift twin `GeminiClient.parseModels` — the same fixtures must yield
 * the same ids on both platforms: strip the `models/` prefix, keep chat-capable `gemini*` only,
 * drop embeddings / AQA.
 */
class GeminiModelParseTest {

    @Test
    fun `strips the models prefix and keeps chat-capable gemini ids`() {
        val json = """
            {"models":[
              {"name":"models/gemini-2.5-pro"},
              {"name":"models/gemini-2.5-flash"},
              {"name":"models/gemini-2.0-flash"}
            ]}
        """.trimIndent()
        assertEquals(
            listOf("gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"),
            AiCoach.parseGeminiModels(json),
        )
    }

    @Test
    fun `drops embedding and aqa and non-gemini models`() {
        val json = """
            {"models":[
              {"name":"models/gemini-2.5-flash"},
              {"name":"models/embedding-001"},
              {"name":"models/text-embedding-004"},
              {"name":"models/gemini-embedding-001"},
              {"name":"models/aqa"},
              {"name":"models/gemma-3-27b-it"}
            ]}
        """.trimIndent()
        // Only the plain chat gemini stays: embedding/aqa are dropped even when prefixed "gemini",
        // and non-gemini families (gemma) are not in this curated fetch.
        assertEquals(listOf("gemini-2.5-flash"), AiCoach.parseGeminiModels(json))
    }

    @Test
    fun `malformed or empty bodies yield an empty list, never throw`() {
        assertEquals(emptyList<String>(), AiCoach.parseGeminiModels(""))
        assertEquals(emptyList<String>(), AiCoach.parseGeminiModels("not json"))
        assertEquals(emptyList<String>(), AiCoach.parseGeminiModels("""{"data":[{"id":"gpt-4o"}]}"""))
        assertEquals(emptyList<String>(), AiCoach.parseGeminiModels("""{"models":[]}"""))
    }

    @Test
    fun `a bare name without the models prefix is kept as-is`() {
        assertEquals(
            listOf("gemini-2.5-flash"),
            AiCoach.parseGeminiModels("""{"models":[{"name":"gemini-2.5-flash"}]}"""),
        )
    }
}
