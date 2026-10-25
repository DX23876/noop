package com.noop.ui

import com.noop.analytics.MarkerCatalog
import java.math.BigDecimal
import java.math.RoundingMode

/**
 * How the Lab Book prints a marker's numeric value. Twin of Swift `LabBookFormat.value` / `.plain`
 * (Strand/Screens/LabBookView.swift); both are pinned by the same expected strings.
 *
 * Rounding works on the double's exact binary value, as Swift's `String(format: "%.Nf")` does, with ties
 * to even; `String.format` rounds ties half-up, so an exact tie such as 0.125 at 2 decimals printed
 * "0.13" here and "0.12" on Apple.
 */
object LabValueFormat {
    /** Catalog markers use their declared decimals; a custom marker is shown at its own precision via [plain]. */
    fun value(v: Double, key: String): String {
        if (!v.isFinite()) return "—"
        val decimals = MarkerCatalog.definition(key)?.decimals ?: return plain(v)
        return fixed(v, decimals)
    }

    /** Up to 3 decimals with trailing zeros dropped ("0.27", "1.02", "140"), "." separator, never "-0". */
    fun plain(v: Double): String {
        if (!v.isFinite()) return "—"
        val s = fixed(v, 3).trimEnd('0').removeSuffix(".")
        return if (s == "-0") "0" else s
    }

    /**
     * [decimals] == 0 matches Swift `String(Int(v.rounded()))` (half away from zero, no "-0"); otherwise
     * `String(format: "%.Nf")` (exact value, ties to even, "-" kept for any negative input incl. -0.0).
     */
    internal fun fixed(v: Double, decimals: Int): String {
        if (decimals == 0) return BigDecimal(v).setScale(0, RoundingMode.HALF_UP).toPlainString()
        val magnitude = BigDecimal(v).abs().setScale(decimals, RoundingMode.HALF_EVEN).toPlainString()
        return if (java.lang.Double.doubleToRawLongBits(v) < 0) "-$magnitude" else magnitude
    }
}
