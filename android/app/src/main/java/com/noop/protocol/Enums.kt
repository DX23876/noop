package com.noop.protocol

/**
 * On-wire enums for the WHOOP protocol. Each constant carries its raw (on-wire) Int value and
 * every enum offers a `fromRaw(Int)` companion lookup that returns null for unknown codes.
 *
 * Values mirror the canonical schema (whoop_protocol.json) and the project SHARED CONTRACT.
 * These are deliberately a curated subset of the full device enum tables — only the codes the
 * offline companion app reads or sends. Unknown codes are surfaced by name elsewhere (see
 * [Framing.enumLabel]); they are not added here so the enums stay small and intentional.
 */

/** Frame packet type (envelope byte at offset 4 for Whoop 4.0). */
enum class PacketType(val rawValue: Int) {
    COMMAND(35),
    COMMAND_RESPONSE(36),
    PUFFIN_COMMAND(37),
    PUFFIN_COMMAND_RESPONSE(38),
    REALTIME_DATA(40),
    REALTIME_RAW_DATA(43),
    HISTORICAL_DATA(47),
    EVENT(48),
    METADATA(49),
    CONSOLE_LOGS(50),
    REALTIME_IMU_DATA_STREAM(51),
    HISTORICAL_IMU_DATA_STREAM(52);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): PacketType? = byRaw[raw]
    }
}

/** METADATA frame sub-type (historical-offload state machine). */
enum class MetadataType(val rawValue: Int) {
    HISTORY_START(1),
    HISTORY_END(2),
    HISTORY_COMPLETE(3);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): MetadataType? = byRaw[raw]
    }
}

/**
 * EVENT frame event code (offset 6 in an EVENT frame).
 *
 * The FULL shared `EventNumber` catalogue, kept in lockstep with
 * `WhoopProtocol/Resources/whoop_protocol.json` — the cross-platform contract says a frame must label
 * identically on both platforms. Only 13 of these were listed before, so everything else rendered as a
 * bare `0x44(68)` in an Android strap log while iOS named it; #791 was filed partly on the strength of an
 * "uncatalogued" event that iOS already knew. That gap makes an Android bug report unable to say what the
 * strap is reporting — RTC_LOST, BOOT, BLE_SYSTEM_RESET and EXTENDED_BATTERY_INFORMATION all arrived
 * anonymous.
 *
 * Names only. Event PAYLOAD decoding stays exactly as it was: family-gated and deliberately conservative,
 * because several of these payloads have no on-device 5.0 ground truth and are left raw rather than ported
 * from 4.0 on faith (see `decodeWhoop5Event`). A name here does not imply a decoder.
 *
 * A number absent from the schema still falls through to `hexLabel`, and is NEVER given an invented name —
 * event 68 (`0x44`) observed on a real 4.0 in #791 is unknown to both platforms and stays unknown.
 */
enum class EventNumber(val rawValue: Int) {
    UNDEFINED(0),
    ERROR(1),
    CONSOLE_OUTPUT(2),
    BATTERY_LEVEL(3),
    SYSTEM_CONTROL(4),
    EXTERNAL_5V_ON(5),
    EXTERNAL_5V_OFF(6),
    CHARGING_ON(7),
    CHARGING_OFF(8),
    WRIST_ON(9),
    WRIST_OFF(10),
    BLE_CONNECTION_UP(11),
    BLE_CONNECTION_DOWN(12),
    RTC_LOST(13),
    DOUBLE_TAP(14),
    BOOT(15),
    SET_RTC(16),
    TEMPERATURE_LEVEL(17),
    PAIRING_MODE(18),
    SERIAL_HEAD_CONNECTED(19),
    SERIAL_HEAD_REMOVED(20),
    BATTERY_PACK_CONNECTED(21),
    BATTERY_PACK_REMOVED(22),
    BLE_BONDED(23),
    BLE_HR_PROFILE_ENABLED(24),
    BLE_HR_PROFILE_DISABLED(25),
    TRIM_ALL_DATA(26),
    TRIM_ALL_DATA_ENDED(27),
    FLASH_INIT_COMPLETE(28),
    STRAP_CONDITION_REPORT(29),
    BOOT_REPORT(30),
    EXIT_VIRGIN_MODE(31),
    CAPTOUCH_AUTOTHRESHOLD_ACTION(32),
    BLE_REALTIME_HR_ON(33),
    BLE_REALTIME_HR_OFF(34),
    ACCELEROMETER_RESET(35),
    AFE_RESET(36),
    SHIP_MODE_ENABLED(37),
    SHIP_MODE_DISABLED(38),
    SHIP_MODE_BOOT(39),
    CH1_SATURATION_DETECTED(40),
    CH2_SATURATION_DETECTED(41),
    ACCELEROMETER_SATURATION_DETECTED(42),
    BLE_SYSTEM_RESET(43),
    BLE_SYSTEM_ON(44),
    BLE_SYSTEM_INITIALIZED(45),
    RAW_DATA_COLLECTION_ON(46),
    RAW_DATA_COLLECTION_OFF(47),
    STRAP_DRIVEN_ALARM_SET(56),
    STRAP_DRIVEN_ALARM_EXECUTED(57),
    APP_DRIVEN_ALARM_EXECUTED(58),
    STRAP_DRIVEN_ALARM_DISABLED(59),
    HAPTICS_FIRED(60),
    EXTENDED_BATTERY_INFORMATION(63),
    HIGH_FREQ_SYNC_PROMPT(96),
    HIGH_FREQ_SYNC_ENABLED(97),
    HIGH_FREQ_SYNC_DISABLED(98),
    HAPTICS_TERMINATED(100);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): EventNumber? = byRaw[raw]
    }
}

/**
 * Curated, SAFE command codes for *sending* to the strap. Destructive commands
 * (reboot / firmware load / force-trim / ship-mode / power-cycle / fuel-gauge reset / BLE DFU)
 * are deliberately excluded so the in-app sender can never brick or wipe the device.
 */
enum class CommandNumber(val rawValue: Int) {
    TOGGLE_REALTIME_HR(3),
    // REPORT_VERSION_INFO (7): WHOOP 4.0 firmware/version read. The strap answers with the bundled
    // component versions (`fw_harvard` a.b.c.d, `fw_boylston` a.b.c.d). A documented READ command,
    // separate from the firmware-LOAD opcodes. Mirrors Swift `WhoopCommand.reportVersionInfo`.
    REPORT_VERSION_INFO(7),
    SET_CLOCK(10),
    GET_CLOCK(11),
    SEND_HISTORICAL_DATA(22),
    // The historical-offload trim/ack command. Sent (with response) to confirm one HISTORY_END
    // chunk so the strap may trim it; payload = [0x01] + the verbatim 8-byte HISTORY_END end_data.
    // Port of Swift `WhoopCommand.historicalDataResult` (whoop_protocol.json: 23 HISTORICAL_DATA_RESULT).
    HISTORICAL_DATA_RESULT(23),
    GET_BATTERY_LEVEL(26),
    // REBOOT_STRAP (29) — restart the strap. Empty body (the official app's builder passes a null
    // payload). The strap drops the link and re-advertises after boot; stored data is KEPT
    // (non-destructive), though an in-flight offload is interrupted (chunk-acked, so nothing is lost).
    // Opcode 29 is shared across WHOOP 4.0 (harvard/crc8) and 5/MG (puffin/crc16). The 5.0 form is
    // hardware-confirmed (fw 50.40.1.0, #227); the 4.0 form is NOT — a real 4.0 silently IGNORES this
    // empty-body frame (#235: no reboot, no disconnect, no COMMAND_RESPONSE), so the correct 4.0 frame
    // still needs an HCI capture. rebootStrap() logs the COMMAND_RESPONSE + a no-disconnect watchdog so a
    // strap log shows which case it hit. User-initiated + confirmation-gated only; never automatic.
    // Port of Swift WhoopCommand.rebootStrap.
    REBOOT_STRAP(29),
    // POWER_CYCLE_STRAP (32) — a harder restart than REBOOT_STRAP (a full power cycle of the strap SoC
    // vs a warm reboot). Non-destructive: stored data lives in flash and survives, the strap re-advertises
    // after boot. Included ONLY as a gated candidate for the WHOOP 4.0 reboot probe (#235: a real 4.0
    // silently ignores opcode 29/empty, and the correct 4.0 reboot frame is unknown). NOT hardware-confirmed
    // on any family. Sent only via rebootProbe(POWER_CYCLE_32_EMPTY), itself gated behind Test Centre →
    // Connection + a confirmation. Never sent automatically. Port of Swift WhoopCommand.powerCycleStrap.
    POWER_CYCLE_STRAP(32),
    GET_DATA_RANGE(34),
    GET_HELLO_HARVARD(35),
    // GET_HELLO (145): WHOOP 5.0/MG hello. The response carries the device name plus `fw_version`
    // a.b.c.d. Older 4.0 firmware replies "unsupported" (0a03) and is ignored. Mirrors Swift
    // `WhoopCommand.getHello`.
    GET_HELLO(145),
    SEND_R10_R11_REALTIME(63),
    // WHOOP 5.0/MG (device family GOOSE/MAVERICK) one-shot buzz. Gen-4 straps use the legacy
    // RUN_HAPTICS_PATTERN(79) below; a 5/MG strap only honors this command.
    RUN_HAPTIC_PATTERN_MAVERICK(19),
    SET_ALARM_TIME(66),
    GET_ALARM_TIME(67),
    RUN_ALARM(68),
    DISABLE_ALARM(69),
    // SET_ADVERTISING_NAME_HARVARD (77) — rename the WHOOP 4.0's BLE advertising name on the strap
    // firmware (the name the OS shows in Bluetooth). Payload: [0x00,0x00] + UTF-8 name + [0x00]; the
    // strap reboots to apply. WHOOP 4.0 only (a 5/MG uses puffin framing + a different config path).
    // Port of Swift WhoopCommand.setAdvertisingNameHarvard.
    SET_ADVERTISING_NAME(77),
    RUN_HAPTICS_PATTERN(79),
    GET_ALL_HAPTICS_PATTERN(80),
    // SET_CONFIG / SET_FF_VALUE (0x78) — write one persistent feature flag. The 5/MG "enable R22
    // packets" sequence (Whoop5Config) sends 15 of these to switch on the deep biometric streams.
    // Reversible; gated behind the deep-data opt-in; iOS/Android only. (#174)
    SET_CONFIG(120),
    // SET_DEVICE_CONFIG (0x77) — write one persistent DEVICE-config value (distinct from the
    // feature-flag SET_CONFIG/0x78). Used for the "Broadcast HR" flag whoop_live_hr_in_adv_ind_pkt,
    // which makes the strap advertise its HR as a standard 0x180D BLE sensor. Validated on real
    // hardware (paired on a Garmin Edge 840). Reversible; gated behind the broadcast-HR opt-in. (#181)
    SET_DEVICE_CONFIG(119),
    START_RAW_DATA(81),
    STOP_RAW_DATA(82),
    // GET_EXTENDED_BATTERY_INFO (98) — read-only extended battery read (mV etc.). The NUMBER is disputed
    // (#592): an independent APK decompile reads this family 11 lower (87), while whoomp's table says 98 —
    // partially supported by a real WHOOP 5 (fw 50.38.1.0) ANSWERING 98, though with a short stub that
    // could be valid-but-minimal or a generic unknown-command ack. Sent ONLY by probeExtendedBatteryInfo()
    // (user-initiated, Test Centre → Connection gated, never automatic); the raw COMMAND_RESPONSE is
    // dumped in full to the strap log so a normal export settles which number this firmware serves.
    // Mirrors Swift WhoopCommand.getExtendedBatteryInfo.
    GET_EXTENDED_BATTERY_INFO(98),
    // #690: read-only body-location/status probe. Documented in the WHOOP protocol; driven only by the
    // user-triggered, Test-Centre-gated probeBodyLocationAndStatus(). Decoded to a diagnostic report only.
    GET_BODY_LOCATION_AND_STATUS(84),
    STOP_HAPTICS(122),
    SELECT_WRIST(123);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): CommandNumber? = byRaw[raw]
    }
}

/**
 * Candidate reboot frames for the WHOOP 4.0 reboot probe (Test Centre → Connection, WHOOP 4.0 only).
 *
 * A real WHOOP 4.0 silently ignores NOOP's production reboot frame (opcode 29 REBOOT_STRAP, empty body
 * — #235: no reboot, no disconnect, no COMMAND_RESPONSE), and the correct 4.0 frame is unknown. These
 * are the plausible NON-DESTRUCTIVE candidates — a restart / power-cycle only, never a data-wiping
 * opcode — tried one at a time on real hardware so the strap log tells which one works: `reboot: link
 * dropped …` = the strap acted; `reboot: no disconnect within 12s …` = ignored.
 *
 * The definitive fix is still an HCI capture of the official app rebooting a 4.0 (exactly how the alarm
 * frame was pinned — @ujix's capture, #535). This probe is the interim way to find the frame when a 4.0
 * is in hand. Twin of Swift `RebootProbeVariant` (Commands.swift); the [logTag] strings are byte-identical
 * across platforms so a strap log reads the same either side.
 */
enum class RebootProbeVariant(
    val command: CommandNumber,
    val payload: ByteArray,
    /** Short menu label, e.g. "A · REBOOT_STRAP(29) empty". */
    val menuLabel: String,
    /** Tag written to the strap log so each attempt is correlatable (byte-identical to Swift). */
    val logTag: String,
) {
    // A — opcode 29 REBOOT_STRAP, empty body: NOOP's current production frame (ignored on 4.0).
    REBOOT_29_EMPTY(CommandNumber.REBOOT_STRAP, byteArrayOf(),
        "A · REBOOT_STRAP(29) empty", "A/reboot29-empty"),
    // B — opcode 32 POWER_CYCLE_STRAP, empty body: a harder restart, never tried.
    POWER_CYCLE_32_EMPTY(CommandNumber.POWER_CYCLE_STRAP, byteArrayOf(),
        "B · POWER_CYCLE(32) empty", "B/powercycle32-empty"),
    // C — opcode 29 REBOOT_STRAP, payload [0x01]: same opcode with a non-empty sub-command byte.
    // On a real 4.0 this DROPPED THE LINK but did NOT power-cycle (sensor stayed on) — a BLE
    // disconnect, not a reboot (#275). So the sub-command byte reaches the strap; the next two try it
    // on the harder power-cycle opcode and a different byte on reboot.
    REBOOT_29_PAYLOAD1(CommandNumber.REBOOT_STRAP, byteArrayOf(0x01),
        "C · REBOOT_STRAP(29) payload=01", "C/reboot29-payload01"),
    // D — opcode 32 POWER_CYCLE_STRAP, payload [0x01]: the "harder restart" opcode with the sub-command
    // byte that made 29 react (#275). Best remaining safe candidate for a genuine power-cycle.
    POWER_CYCLE_32_PAYLOAD1(CommandNumber.POWER_CYCLE_STRAP, byteArrayOf(0x01),
        "D · POWER_CYCLE(32) payload=01", "D/powercycle32-payload01"),
    // E — opcode 29 REBOOT_STRAP, payload [0x00]: the zero-byte sub-command (vs empty vs 0x01).
    REBOOT_29_PAYLOAD0(CommandNumber.REBOOT_STRAP, byteArrayOf(0x00),
        "E · REBOOT_STRAP(29) payload=00", "E/reboot29-payload00"),
}
