package com.noop.protocol

/** Which checksum guards the frame header for a given device family. */
enum class HeaderCRCKind {
    /** CRC8 (poly 0x07) over the two declared-length bytes — Whoop 4.0. */
    CRC8,

    /** CRC16-Modbus (poly 0xA001, init 0xFFFF, reflected) over the header prefix — Whoop 5.0. */
    CRC16_MODBUS,
}

/**
 * Which WHOOP hardware generation a connection / capture belongs to.
 *
 * This module is platform-pure: it never imports Android Bluetooth types. The BLE layer is
 * responsible for turning the UUID *strings* exposed here into `UUID`/`ParcelUuid` values. Keeping
 * platform UUID types out of this module lets the protocol code run on a plain JVM (and in tests).
 */
enum class DeviceFamily {
    /** Whoop 4.0 — 0x07 CRC8 header check. */
    WHOOP4,

    /** Whoop 5.0 / MG — CRC16-Modbus header check, "puffin" packet types. */
    WHOOP5;

    /** The header-CRC algorithm this family uses; the payload CRC32 is identical for both. */
    val headerCRCKind: HeaderCRCKind
        get() = when (this) {
            WHOOP4 -> HeaderCRCKind.CRC8
            WHOOP5 -> HeaderCRCKind.CRC16_MODBUS
        }

    /** Primary GATT service UUID *string* for this family (lowercase, as advertised). */
    val serviceUuidString: String
        get() = when (this) {
            WHOOP4 -> "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
            WHOOP5 -> "fd4b0001-cce1-4033-93ce-002d5875f58a"
        }

    /** Characteristic UUID *strings* this family uses, in stable ascending order. */
    val characteristicUuidStrings: List<String>
        get() = when (this) {
            WHOOP4 -> listOf(
                "61080002-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
            )
            WHOOP5 -> listOf(
                "fd4b0002-cce1-4033-93ce-002d5875f58a",
                "fd4b0003-cce1-4033-93ce-002d5875f58a",
                "fd4b0004-cce1-4033-93ce-002d5875f58a",
                "fd4b0005-cce1-4033-93ce-002d5875f58a",
                "fd4b0007-cce1-4033-93ce-002d5875f58a",
            )
        }

    /**
     * The command/write characteristic UUID *string* for this family (the …0002 endpoint that
     * CLIENT_HELLO and command frames are written to). A single confirmed write here is the bond.
     */
    val commandCharacteristicUuidString: String
        get() = when (this) {
            WHOOP4 -> "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
            WHOOP5 -> "fd4b0002-cce1-4033-93ce-002d5875f58a"
        }

    /**
     * Static CLIENT_HELLO frame this family writes immediately after GATT discovery to start a
     * session, or `null` for families that do not use a fixed hello.
     *
     * The Whoop 5.0 hello is a fully-formed type-35 (COMMAND) frame with CRC16-Modbus header and
     * CRC32 payload trailer. Transcribed verbatim from the Goose reverse-engineering
     * (`GooseHello.clientHelloFrameHex` = "aa0108000001e67123019101363e5c8d").
     */
    val clientHello: ByteArray?
        get() = when (this) {
            WHOOP4 -> null
            WHOOP5 -> WHOOP5_CLIENT_HELLO.copyOf()
        }

    companion object {
        /**
         * Resolve a device-registry `model` label to the strap family that wrote its rows (#171).
         *
         * The registry holds several historical spellings for the same hardware: the Add-Device
         * wizard stores bare "4.0" / "5.0 MG", other paths match the full picker labels
         * ("WHOOP 4.0" / "WHOOP 5.0 / MG"), and the legacy seeded "my-whoop" row stores just
         * "WHOOP". Matching any single spelling silently misses the others (#171), so this is
         * the ONE place allowed to interpret registry model labels.
         *
         * "WHOOP" predates the wizard and was written identically for 4.0 and 5/MG installs, so
         * it carries no family information; it keeps the prior WHOOP5 fallback, as do
         * null/unknown labels (non-WHOOP imports whose skin temp is already °C) — only a
         * positively-identified 4.0 changes scale (#938). Mirrors the Swift
         * `DeviceFamily.forRegistryModel`.
         */
        fun forRegistryModel(model: String?): DeviceFamily = when (model) {
            "4.0", "WHOOP 4.0" -> WHOOP4
            else -> WHOOP5
        }

        /** Whoop 5.0 CLIENT_HELLO bytes (16 bytes). Exposed as a named constant for test/debug use. */
        val WHOOP5_CLIENT_HELLO: ByteArray = byteArrayOf(
            0xAA.toByte(), 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6.toByte(), 0x71,
            0x23, 0x01, 0x91.toByte(), 0x01, 0x36, 0x3E, 0x5C, 0x8D.toByte(),
        )
    }
}

/**
 * Whoop 5.0 "puffin" packet types mirror existing 4.0 types on the new transport. These map onto
 * the canonical base type names so they decode like their 4.0 counterparts instead of falling
 * through to an "unknown" label.
 */
object PuffinPacketType {
    /** Puffin command response — behaves like COMMAND_RESPONSE (type 36). */
    const val PUFFIN_COMMAND_RESPONSE: Int = 38

    /** Puffin metadata — behaves like METADATA (type 49). */
    const val PUFFIN_METADATA: Int = 56
}
