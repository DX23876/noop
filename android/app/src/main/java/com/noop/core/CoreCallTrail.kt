package com.noop.core

/**
 * The last handful of calls across the core bridge, for the crash report.
 *
 * A Java heap death names the frame that asked for the next allocation, which is almost never the frame
 * that filled the heap. The tester report of 2026-11-19 is the worked example: `OutOfMemoryError` at
 * `SwiftCore.call`, failing on 592 bytes with the heap at its 256 MB growth limit. Retraced, the frame was
 * the Today coach card (`coach.today`), whose answer is eight short strings. It was the straw, and the
 * report said nothing about the load.
 *
 * So the bridge keeps what it moved: the call in flight and the last [KEEP] that finished, each with the
 * size of what crossed. That is rare-event evidence in the sense `AGENTS.md` asks for — it costs a few
 * small objects while nothing is wrong, and it is the thing that is missing when a report arrives.
 *
 * Deliberately NOT a diagnosis. The trail states sizes and ages, never a culprit: a large answer near a
 * crash is a candidate, not a cause, and whoever reads the report decides.
 */
object CoreCallTrail {
    /** How many finished calls the trail keeps. */
    const val KEEP = 8

    /** One finished call: what crossed, and how long ago. */
    class Entry(val op: String, val argsChars: Int, val answerChars: Int, val ms: Long, val atMs: Long)

    private val entries = ArrayDeque<Entry>(KEEP)

    /** The call that has not come back, if any; written before the jump into Swift. */
    @Volatile private var inFlight: String? = null
    @Volatile private var inFlightAtMs: Long = 0L

    fun begin(op: String, argsChars: Int) {
        inFlight = "$op args=${chars(argsChars)}"
        inFlightAtMs = System.currentTimeMillis()
    }

    /** [answerChars] is -1 when the core answered null. */
    fun done(op: String, argsChars: Int, answerChars: Int, ms: Long) {
        inFlight = null
        val entry = Entry(op, argsChars, answerChars, ms, System.currentTimeMillis())
        synchronized(entries) {
            entries.addLast(entry)
            while (entries.size > KEEP) entries.removeFirst()
        }
    }

    /** Newest first. */
    fun recent(): List<Entry> = synchronized(entries) { entries.toList().asReversed() }

    /**
     * The block the crash report carries, or null when the bridge was never used. Pure apart from the
     * trail itself, so the formatting is testable without a core.
     */
    fun report(nowMs: Long = System.currentTimeMillis()): String? {
        val pending = inFlight
        val recent = recent()
        if (pending == null && recent.isEmpty()) return null
        return buildString {
            appendLine("core calls (newest first):")
            if (pending != null) appendLine("  in flight: $pending, ${nowMs - inFlightAtMs} ms ago")
            for (e in recent) appendLine("  " + line(e, nowMs))
        }
    }

    internal fun line(e: Entry, nowMs: Long): String {
        val answer = if (e.answerChars < 0) "null" else chars(e.answerChars)
        return "${e.op} args=${chars(e.argsChars)} answer=$answer ${e.ms} ms, ${nowMs - e.atMs} ms ago"
    }

    /** A character count as the reader needs it: the Java string is two bytes per character. */
    internal fun chars(count: Int): String = when {
        count < 0 -> "null"
        count < 10_000 -> "$count"
        count < 10_000_000 -> "${count / 1_000}k"
        else -> "${count / 1_000_000}M"
    }

    /** Only for tests: the trail starts empty. */
    internal fun clearForTest() {
        inFlight = null
        synchronized(entries) { entries.clear() }
    }
}
