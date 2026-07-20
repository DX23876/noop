package com.noop.testcentre

/**
 * The mandatory review-before-share gate (spec sections 9 and 12), twin of
 * Strand/System/ReportReviewGate.swift. Nothing is shared until the user has seen the exact redacted
 * report.txt and explicitly confirmed. Not skippable: confirm() is the only path to cleared. The
 * Compose review sheet binds to previewText and calls confirm() / cancel().
 */
class ReportReviewGate(private val entries: List<Pair<String, ByteArray>>) {

    var isCleared: Boolean = false
        private set

    /**
     * Every text file the user is about to share, so they can read the WHOLE bundle (not just report.txt)
     * and cancel if anything looks personal. Each text entry is prefixed with a `=== <name> ===` header so
     * report.txt, meta.json, and last-crash.txt (when present) are clearly delimited. The raw-capture
     * stream is excluded: it is the bounded binary capture (up to the 20 MB cap), not a report surface, and
     * is already PII-scrubbed by the assembler. "" if there is nothing text-decodable to show. Mirrors Swift.
     */
    val previewText: String
        get() {
            // #570 parity: text files shown inline; the large raw streams (by NAME), any binary attachment,
            // and ANYTHING over the size guard are excluded — rendering megabytes as one Compose Text risks
            // the layout choke iOS hit — and EVERY excluded entry is NAMED below so the review stays honest
            // about the WHOLE bundle. Mirrors Swift.
            val textBlocks = entries
                .filterNot { (name, data) -> isExcludedFromInline(name, data.size) }
                .joinToString("\n\n") { (name, data) -> "=== $name ===\n${String(data)}" }
            val excludedNames = entries
                .filter { (name, data) -> isExcludedFromInline(name, data.size) }
                .map { it.first }
            if (excludedNames.isEmpty()) return textBlocks
            val note = "=== attached (not shown above) ===\n" + excludedNames.joinToString("\n")
            return if (textBlocks.isEmpty()) note else textBlocks + "\n\n" + note
        }

    /** A bundle entry that is binary image bytes (not text to show inline). screenshot.png is the only one. */
    private fun isBinaryEntry(name: String): Boolean = name == DisplayScreenshot.BUNDLE_NAME

    /** #570 parity: an entry NEVER shown inline — a binary, a large raw research stream (by name), or ANY
     *  entry over [MAX_INLINE_BYTES] (a future stream, or a pathologically large report.txt). The size guard
     *  is belt-and-braces so no single Compose Text can choke the review sheet regardless of what a branch
     *  attaches. Mirrors Swift ReportReviewGate.notShownInline + maxInlineBytes. */
    private fun isExcludedFromInline(name: String, size: Int): Boolean =
        isBinaryEntry(name) || name in NOT_SHOWN_INLINE || size > MAX_INLINE_BYTES

    companion object {
        /** Large raw research streams never shown inline by NAME: the WHOOP frame capture plus the Oura
         *  Tier-B sidecars (harmless on Android today — it doesn't attach them — but kept for parity and a
         *  future producer port). The binary screenshot is caught by [isBinaryEntry]. */
        private val NOT_SHOWN_INLINE = setOf(
            "raw-capture.jsonl", "oura-raw.jsonl", "oura-ibihr.jsonl", "oura-activity.jsonl",
        )

        /** 1 MiB — far above a normal report.txt / meta.json (those still show in full) yet well below the
         *  Compose-text layout-choke point. Mirrors Swift `maxInlineBytes`. */
        private const val MAX_INLINE_BYTES = 1024 * 1024
    }

    /** Explicit user confirmation: the only way the gate clears. */
    fun confirm() { isCleared = true }
    /** Explicit cancel: leaves the gate uncleared so the share never fires. */
    fun cancel() { isCleared = false }
}
