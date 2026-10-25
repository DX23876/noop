package com.noop.ui

/**
 * A process-wide, time-bounded ring buffer of strap-log lines for the SCHEDULED debug export (#510,
 * maddognik).
 *
 * WHY this is separate from [com.noop.ble.WhoopBleClient]'s own `logBuffer`: that one lives on the live
 * BLE client instance, which is owned by the ViewModel / foreground service and is NOT reachable from a
 * background [androidx.work.Worker] running hours later (possibly after the client was torn down). The
 * scheduled daily export needs its OWN durable, independently-addressable tail of the log, so [LogExport]
 * mirrors every line it ships into here and [DebugExportScheduler]'s worker reads it back with no live
 * BLE dependency.
 *
 * BOUNDED two ways, whichever bites first, so it can never grow without limit:
 *   • a hard cap of [MAX_LINES] entries (matches the client's 5000-line cap), AND
 *   • a ~24h rolling window — lines older than [RETENTION_MS] are dropped on every append/read.
 *
 * Each entry carries the wall-clock epoch it was appended so the time window can be enforced without
 * parsing the line text. Lines are stored already-redacted (LogExport appends the client's
 * `exportLogText()`, which is PII-scrubbed at source — #445), so nothing un-redacted ever lands here.
 *
 * All access is synchronized: appends arrive from the UI thread (LogExport) and reads from a WorkManager
 * background thread (the scheduler). Pure JVM logic — no Android types — so it unit-tests directly.
 */
object StrapLogBuffer {

    /** One retained line: the wall-clock epoch (ms) it was recorded, plus the already-redacted text. */
    private data class Entry(val tsMs: Long, val line: String)

    private val lines = ArrayDeque<Entry>()

    /**
     * Append [text] to the rolling buffer, splitting on newlines so multi-line blobs (e.g. the whole
     * `exportLogText()` snapshot) become individually-aged entries. Blank input is ignored. Each line is
     * stamped with [nowMs] and the buffer is trimmed afterwards so it stays inside both bounds.
     *
     * [nowMs] is injectable purely so the unit test can age entries deterministically; production callers
     * use the default wall clock.
     */
    @Synchronized
    fun append(text: String, nowMs: Long = System.currentTimeMillis()) {
        if (text.isBlank()) return
        for (raw in text.split('\n')) {
            // Keep blank interior lines that sit between real content (formatting), but skip a trailing
            // empty split so "a\n" doesn't bank a phantom line.
            lines.addLast(Entry(nowMs, raw))
        }
        trim(nowMs)
    }

    /**
     * Replace the buffer's contents with a fresh snapshot (newest last). Used when LogExport ships the
     * client's full `exportLogText()` tail: the client already holds the authoritative recent window, so
     * mirroring is a REPLACE (not an append) to avoid duplicating the overlap on every export. Still
     * bounded + aged on the way in.
     */
    @Synchronized
    fun replaceWith(text: String, nowMs: Long = System.currentTimeMillis()) {
        lines.clear()
        append(text, nowMs)
    }

    /** Newest-last snapshot of the retained lines as a single string, aged to the window first. Empty
     *  string when nothing is retained. */
    @Synchronized
    fun snapshot(nowMs: Long = System.currentTimeMillis()): String {
        trim(nowMs)
        return lines.joinToString("\n") { it.line }
    }

    /** Current retained line count (after aging) — for tests + diagnostics. */
    @Synchronized
    fun size(nowMs: Long = System.currentTimeMillis()): Int {
        trim(nowMs)
        return lines.size
    }

    /** Drop everything (used by tests; never needed in production). */
    @Synchronized
    fun clear() = lines.clear()

    /** Enforce BOTH bounds: drop anything older than the retention window, then cap the line count. */
    private fun trim(nowMs: Long) {
        val cutoff = nowMs - RETENTION_MS
        while (lines.isNotEmpty() && lines.first().tsMs < cutoff) lines.removeFirst()
        while (lines.size > MAX_LINES) lines.removeFirst()
    }

    /** ~24h rolling window. */
    const val RETENTION_MS: Long = 24L * 60L * 60L * 1000L

    /** Hard line cap, mirroring WhoopBleClient.LOG_BUFFER_MAX so the two logs hold a comparable tail. */
    const val MAX_LINES = 5000
}
