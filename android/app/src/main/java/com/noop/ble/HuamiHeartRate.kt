package com.noop.ble

/**
 * Pure parser for the Huami / Zepp (Amazfit, Mi Band) custom heart-rate notification.
 *
 * Faithful Kotlin twin of Strand/BLE/HuamiHeartRate.swift.
 *
 * CLEAN-ROOM. NOOP's own implementation from PUBLICLY DOCUMENTED protocol FACTS about the Huami family
 * (the GATT layout is documented in several open projects — we reuse only the FACTS: the service /
 * characteristic UUIDs and the on-wire byte layout — and wrote our own code). No GPL/AGPL code copied.
 *
 * DOCUMENTED FACT (the layout this parser decodes):
 *   - Huami devices expose a custom HR service `0000fee0-…` and a custom HR *measurement* characteristic
 *     `00002a37-0000-3512-2118-0009af100700` (same 0x2A37 short form as the standard SIG characteristic
 *     but on the Huami 128-bit base — a DIFFERENT characteristic).
 *   - Newer bands also implement the *standard* SIG Heart Rate Service (0x180D / 0x2A37). When present,
 *     [StandardHrSource]/[StandardHeartRate] already read it — we prefer that and never come here.
 *   - On the Huami custom characteristic the HR value is a single byte, in one of two documented shapes:
 *       - 2-byte `[status, hr]` (byte 0 a status/flags byte, byte 1 the bpm), or
 *       - 1-byte `[hr]`.
 *     We decode both honestly and never guess beyond them.
 *
 * HONESTY: a 0 (no reading) or 255 (the common off-wrist / no-contact sentinel) returns null — the UI
 * shows "—", never a fabricated number.
 *
 * SECURITY / ROBUSTNESS: the buffer is UNTRUSTED BLE input. Every read is bounds-checked; an empty or
 * implausible packet yields null, never a crash or a read past the end (mirrors [StandardHeartRate]).
 */
object HuamiHeartRate {

    /**
     * Extract the heart rate (bpm) from a Huami custom HR-measurement notification, or null when the
     * packet carries no usable reading (empty, a 0/255 sentinel, or implausibly large).
     *
     * @return a bpm in 1..254, or null.
     */
    fun parse(data: ByteArray): Int? {
        if (data.isEmpty()) return null

        // Two documented shapes:
        //   - 1 byte  -> [hr]
        //   - 2 bytes -> [status, hr]
        // For 2+ bytes we take the LAST byte as the bpm: in the [status, hr] form that is the reading, and
        // it degrades safely for the 1-byte form. We never read past the buffer.
        val hr = if (data.size == 1) {
            data[0].toInt() and 0xFF
        } else {
            data[data.size - 1].toInt() and 0xFF
        }

        // 0 = no/last-unknown reading; 255 = the common off-wrist / no-contact sentinel. Both honestly
        // "unknown" -> null so the UI shows "—" rather than a fake 0 or 255.
        return if (hr in 1..254) hr else null
    }
}
