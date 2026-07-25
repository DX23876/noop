package com.noop.protocol

/**
 * Whoop5Variant — WHOOP MG vs plain WHOOP 5.0 hardware discrimination (#520).
 *
 * DELIBERATELY ORTHOGONAL to [DeviceFamily]. `DeviceFamily.WHOOP5` describes the WIRE PROTOCOL
 * (CRC16-Modbus header, puffin packet types) and MG and 5.0 are byte-identical there — every
 * framing/interpreter branch must keep treating them as one family. This type describes the
 * HARDWARE instead: an MG carries the ECG-conductive clasp, a 5.0 does not. Keeping the two apart
 * means a capability gate (ECG, and later BP) can never accidentally change how a frame is parsed.
 *
 * Pure: no Android, no I/O. Faithful twin of WhoopProtocol/Whoop5Variant.swift — keep them
 * byte-identical (same resolution order, same unknown-over-guess rule).
 *
 * Provenance: the serial prefixes and the 5.0 hardware-revision string are protocol FACTS
 * (uncopyrightable), corroborated by community reverse-engineering discussed in #520. They are read
 * from the standard BLE Device Information Service, not from any WHOOP code.
 */
enum class Whoop5Variant(val label: String) {
    /** WHOOP MG — has the ECG-conductive clasp. */
    MG("MG"),
    /** WHOOP 5.0 — no ECG electrodes. */
    FIVE_ZERO("5.0"),
    /** Not identified yet, contradictory evidence, or a non-WHOOP strap. NEVER a guess. */
    UNKNOWN("—");

    /** True only for a POSITIVELY identified MG, so an MG-only feature stays gated off otherwise. */
    val isMG: Boolean get() = this == MG

    companion object {
        /** Serial prefix attesting an MG (BLE DIS Serial Number String, 0x2A25). */
        const val MG_SERIAL_PREFIX = "5AM"
        /** Serial prefix attesting a plain 5.0. */
        const val FIVE_ZERO_SERIAL_PREFIX = "5AG"
        /**
         * Observed 5.0 Hardware Revision String (0x2A27), e.g. "WG50_r52". The MG's own
         * hardware-revision string is NOT yet attested on real hardware, so its absence proves nothing.
         */
        const val FIVE_ZERO_HARDWARE_ID_TOKEN = "WG50"

        /**
         * Resolve the variant from the strap's Device Information Service strings.
         *
         * [serial] is the DIS Serial Number String (0x2A25) or the advertised name (a leading
         * "WHOOP " is tolerated). [hardwareRevision] is the DIS Hardware Revision String (0x2A27).
         *
         * Resolution order, and why:
         *  1. Both present and CONTRADICTORY (hw says 5.0, serial says MG) -> [UNKNOWN]. Only the
         *     5.0 hardware string is attested today, so a contradiction means our model is
         *     incomplete, not that one source wins. Mis-stamping hardware is what #716 cost us.
         *  2. Hardware revision carrying the known 5.0 token -> [FIVE_ZERO] (device-attested).
         *  3. Serial prefix -> [MG] / [FIVE_ZERO].
         *  4. Anything else -> [UNKNOWN]. Never infer from a stray digit in the name (#772).
         */
        fun from(serial: String?, hardwareRevision: String? = null): Whoop5Variant {
            val hw = (hardwareRevision ?: "").uppercase()
            var s = (serial ?: "").uppercase().trim()
            if (s.startsWith("WHOOP ")) s = s.removePrefix("WHOOP ")
            s = s.trim()

            val hwSaysFiveZero = hw.contains(FIVE_ZERO_HARDWARE_ID_TOKEN)
            val serialSaysMG = s.startsWith(MG_SERIAL_PREFIX)

            if (hwSaysFiveZero && serialSaysMG) return UNKNOWN   // contradiction — do not guess
            if (hwSaysFiveZero) return FIVE_ZERO
            if (serialSaysMG) return MG
            if (s.startsWith(FIVE_ZERO_SERIAL_PREFIX)) return FIVE_ZERO
            return UNKNOWN
        }
    }
}
