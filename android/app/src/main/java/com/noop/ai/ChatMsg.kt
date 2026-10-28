package com.noop.ai

/**
 * One turn in the coach conversation.
 *
 * @param id stable identifier (UUID string). Used by K1 streaming to find and replace the
 *   placeholder assistant message as chunks arrive. Defaults to a new UUID so existing callers
 *   are unaffected.
 * @param role "user" or "assistant" — the only two roles the UI history carries. The
 *   system prompt is supplied separately by [AiCoach] and is never stored here.
 * @param text plain-text message body.
 */
data class ChatMsg(
    val id: String = java.util.UUID.randomUUID().toString(),
    val role: String, // "user" | "assistant"
    val text: String,
    /** When it was said, epoch seconds; 0 for a turn from before the shared coach. */
    val date: Double = 0.0,
    /** The line over a message the coach started ("Your daily brief — the coach got in touch"). */
    val gotInTouch: String? = null,
    /** The evidence chain: its header and the sources the reply read. */
    val evidenceHeader: String? = null,
    val evidence: List<String> = emptyList(),
    /** A chart (`plot_metric`) or a card (`show_card`) the coach showed in place of text. */
    val chart: Chart? = null,
    val card: Card? = null,
    /** The memory receipt: what this reply saved (`memoryReceipt`). */
    val saved: List<Saved> = emptyList(),
) {
    data class Saved(val id: String, val line: String, val text: String, val confirmed: Boolean)
    data class Chart(val title: String, val kind: String, val points: List<Pair<Double, Double>>, val lo: Double, val hi: Double)
    data class Card(val kind: String, val title: String, val value: String, val caption: String?,
                    val rows: List<Pair<String, String>>, val tint: String)
}
