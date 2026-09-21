# WHOOP generation-comparative command reference

<a id="whoop-complete-command-reference"></a>

Applicability: [central scope and compatibility](PROTOCOL.md#scope-and-compatibility).

This is the canonical numeric command index for WHOOP 4 and WHOOP 5/MG. It is
not a transmission recommendation or a capability-test allowlist.
Equal numeric IDs are compared here; payload, response, lifecycle and side
effects remain governed by the linked generation contracts.

## Contents

- [Compatibility status](#compatibility-status)
- [Canonical command matrix](#canonical-command-matrix)
- [Unsupported and cross-version commands](#unsupported-and-cross-version-commands)
- [WHOOP 4](#whoop-4)
  - [Version boundaries and negative space](#version-boundaries-and-negative-space)
- [WHOOP 5/MG](#whoop-5mg)
  - [High-frequency sync scheduler](#high-frequency-sync-scheduler)
  - [Haptics and alarms](#haptics-and-alarms)
  - [Service and sensitive operations](#service-and-sensitive-operations)
  - [Ordinary service commands](#ordinary-service-commands)
  - [Image-transfer and certificate commands](#image-transfer-and-certificate-commands)

## Compatibility status

The WHOOP 4 column is version-bounded to **41.17.6.0** for IDs 1–132. Older captures and
interoperability behavior are retained only where they define a useful wire
contract; they do not override a conflicting 41.17.6.0 status.

The WHOOP 5/MG column is version-bounded to **50.42.1.0** and covers every ID
1–159. A supported status means the command is recognized for that version; it
does not by itself guarantee that every request revision, device state or physical
effect has been validated.

| Status | Meaning |
|---|---|
| **S** | Supported for the named firmware version; exact request, response or effect may still be incomplete. |
| **O** | Observed outside the documented command set for the named firmware version. |
| **P** | Partial contract or incomplete device validation. |
| **U** | Not part of the documented command set for the named firmware version. Silence or missing observations do not qualify a command as supported. |
| **?** | Unknown or not investigated for this generation. |

Combined cells such as `O / U` or `P / U` mean that behavior was observed or
implemented outside the documented command set for the named firmware version.
Neither half overrides the other.

The matrix contains every ID 1–159 exactly once. Its two operation columns are
generation-specific: a repeated name does not mean the wire contracts are equal.
WHOOP 4 has 85 `S`, 47 `U` and 27 IDs outside its version-bounded range; WHOOP
5/MG has 71 `S` and 88 `U`. Thirty-four numeric IDs are supported by both
versions, 51 only by WHOOP 4, 15 only by WHOOP 5/MG within the WHOOP 4 range,
and 22 only by WHOOP 5/MG outside it (IDs 138–159). Numeric overlap is not semantic parity. Names are generation-oriented
identifiers; they do not establish payload equality. Requests exclude outer
padding. Common result and correlation rules are in
[transport](PROTOCOL_TRANSPORT.md#responses-and-correlation).

<a id="all-command-ids"></a>

## Canonical command matrix

| ID | WHOOP 4 operation / identifier | W4 status | WHOOP 5/MG operation / identifier | W5 status | Detail contracts |
|---:|---|:---:|---|:---:|---|
| 1 | — | U | `LINK_VALID` | S | [W5](#whoop-5mg) |
| 2 | — | U | — | U | — |
| 3 | `TOGGLE_REALTIME_HR` | P / U | `TOGGLE_REALTIME_HR` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 4 | — | U | — | U | — |
| 5 | — | U | — | U | — |
| 6 | `GET_HARDWARE_INFO` | S | — | U | — |
| 7 | `REPORT_VERSION_INFO` | S | — | U | [W4](#whoop-4) |
| 8 | — | U | — | U | — |
| 9 | — | U | — | U | — |
| 10 | `SET_CLOCK` | O / U | `SET_CLOCK_DEPRECATED` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 11 | `GET_CLOCK` | O / U | `GET_CLOCK_DEPRECATED` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 12 | — | U | — | U | — |
| 13 | — | U | — | U | — |
| 14 | `TOGGLE_GENERIC_HR_PROFILE` | S | `TOGGLE_GENERIC_HR_PROFILE` | S | [W5](#whoop-5mg) |
| 15 | `FORGET_BONDS` | S | `FORGET_BONDS` | S | [W5](#service-and-sensitive-operations) |
| 16 | `TOGGLE_R7_DATA_COLLECTION` | S | — | U | — |
| 17 | — | U | — | U | — |
| 18 | — | U | — | U | — |
| 19 | `SET_R7_REALTIME_STREAM` | S | `RUN_HAPTIC_PATTERN_MAVERICK` | S | [W4](#whoop-4) · [W5](#haptics-and-alarms) |
| 20 | `ABORT_HISTORICAL_TRANSMITS` | O / U | `ABORT_HISTORICAL_TRANSMITS` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 21 | — | U | — | U | — |
| 22 | `SEND_HISTORICAL_DATA` | O / U | `SEND_HISTORICAL_DATA` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 23 | `HISTORICAL_DATA_RESULT` | O / U | `HISTORICAL_DATA_RESULT` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 24 | — | U | — | U | — |
| 25 | `FORCE_TRIM` | S | `FORCE_TRIM` | S | [W5](#service-and-sensitive-operations) |
| 26 | `GET_BATTERY_LEVEL` | S | `GET_BATTERY_LEVEL` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 27 | — | U | — | U | — |
| 28 | — | U | — | U | — |
| 29 | `REBOOT_STRAP` | S | `REBOOT_STRAP` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 30 | — | U | — | U | — |
| 31 | — | U | — | U | — |
| 32 | `POWER_CYCLE_STRAP` | S | `POWER_CYCLE_STRAP` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 33 | `SET_READ_POINTER` | S | `SET_READ_POINTER` | S | [W5](#service-and-sensitive-operations) |
| 34 | `GET_DATA_RANGE` | S | `GET_DATA_RANGE` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 35 | `GET_HELLO_HARVARD` | S | `GET_HELLO_HARVARD` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 36 | `START_FIRMWARE_LOAD` | S | — | U | — |
| 37 | `LOAD_FIRMWARE_DATA` | S | — | U | — |
| 38 | `PROCESS_FIRMWARE_IMAGE` | S | — | U | — |
| 39 | `SET_LED_DRIVE` | S | — | U | — |
| 40 | `GET_LED_DRIVE` | S | — | U | — |
| 41 | `SET_TIA_GAIN` | S | — | U | — |
| 42 | `GET_TIA_GAIN` | S | — | U | — |
| 43 | `SET_BIAS_OFFSET` | S | — | U | — |
| 44 | `GET_BIAS_OFFSET` | S | — | U | — |
| 45 | `ENTER_BLE_DFU` | S | — | U | — |
| 46 | `SEND_R7_PACKETS` | S | — | U | — |
| 47 | `SEND_R9_PACKETS` | S | — | U | — |
| 48 | `SEND_EVENT_PACKETS` | S | `SEND_EVENT_PACKETS` | S | [W5](#whoop-5mg) |
| 49 | `SAVE_R7_PACKETS` | S | — | U | — |
| 50 | `SAVE_R9_PACKETS` | S | — | U | — |
| 51 | `RESET_SIGNAL_PROCESSING` | S | — | U | — |
| 52 | `SET_DP_TYPE` | S | — | U | — |
| 53 | `FORCE_DP_TYPE` | S | — | U | — |
| 54 | `GET_DP_TYPE` | S | — | U | — |
| 55 | `PERSISTENT_SAVE_R10_R11` | S | — | U | — |
| 56 | `PERSISTENT_SAVE_R9` | S | — | U | — |
| 57 | `PERSISTENT_SET_AFE_CHANNEL` | S | — | U | — |
| 58 | `CONFIGURE_RAW_TRANSMIT_ONLY` | S | — | U | — |
| 59 | `SEND_R10_R11_PACKETS` | S | — | U | — |
| 60 | `SAVE_R10_R11_PACKETS` | S | — | U | — |
| 61 | `SET_AFE_PARAMETERS` | S | `SET_AFE_PARAMETERS` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 62 | `GET_AFE_PARAMETERS` | S | `GET_AFE_PARAMETERS` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 63 | `SEND_R10_R11_REALTIME` | S | — | U | [W4](#whoop-4) |
| 64 | `PERSISTENT_SAVE_R10_R11_ALIAS` | S | — | U | — |
| 65 | `GET_PACKET_CONFIG` | S | — | U | — |
| 66 | `SET_ALARM_TIME` | S | `SET_ALARM_TIME` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 67 | `GET_ALARM_TIME` | S | `GET_ALARM_TIME` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 68 | `RUN_ALARM` | S | `RUN_ALARM` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 69 | `DISABLE_ALARM` | S | `DISABLE_ALARM` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 70 | `SAVE_R12_OR_R24_PACKETS` | S | — | U | — |
| 71 | `SEND_R12_OR_R24_PACKETS` | S | — | U | — |
| 72 | `PERSISTENT_SAVE_R12_OR_R24` | S | — | U | — |
| 73 | `SET_SMART_ALARM_HAPTICS_PATTERN` | S | — | U | — |
| 74 | `GET_SMART_ALARM_HAPTICS_PATTERN` | S | — | U | — |
| 75 | `GET_PROTOCOL_VERSION` | S | — | U | — |
| 76 | `GET_ADVERTISING_NAME_HARVARD` | S | — | U | [W4](#whoop-4) |
| 77 | `SET_ADVERTISING_NAME_HARVARD` | S | — | U | [W4](#whoop-4) |
| 78 | `OPERATION_UNRESOLVED` | S | — | U | — |
| 79 | `RUN_HAPTICS_PATTERN` | S | — | U | [W4](#whoop-4) |
| 80 | `GET_ALL_HAPTICS_PATTERN` | S | — | U | — |
| 81 | `START_RAW_DATA` | S | `START_RAW_DATA` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 82 | `STOP_RAW_DATA` | S | `STOP_RAW_DATA` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 83 | `VERIFY_FIRMWARE_IMAGE` | S | `VERIFY_FIRMWARE_IMAGE` | S | [W4](PROTOCOL_UPDATES.md#whoop-4) · [W5](PROTOCOL_UPDATES.md#image-transfer-command-boundaries) |
| 84 | `GET_BODY_LOCATION_AND_STATUS` | S | `GET_BODY_LOCATION_AND_STATUS` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 85 | `LOAD_FIRMWARE_DATA_ALIAS` | S | — | U | — |
| 86 | — | U | — | U | — |
| 87 | — | U | — | U | — |
| 88 | — | U | — | U | — |
| 89 | — | U | — | U | — |
| 90 | — | U | — | U | — |
| 91 | — | U | — | U | — |
| 92 | — | U | — | U | — |
| 93 | — | U | — | U | — |
| 94 | — | U | — | U | — |
| 95 | — | U | — | U | — |
| 96 | `ENTER_HIGH_FREQ_SYNC` | S | `ENTER_HIGH_FREQ_SYNC` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 97 | `EXIT_HIGH_FREQ_SYNC` | S | `EXIT_HIGH_FREQ_SYNC` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 98 | `GET_EXTENDED_BATTERY_INFO` | S | — | U | [W4](#whoop-4) |
| 99 | `RESET_FUEL_GAUGE` | S | — | U | — |
| 100 | `CALIBRATE_CAPSENSE` | S | — | U | — |
| 101 | `RESET_CAPSENSE` | S | — | U | — |
| 102 | `ENABLE_BLE_UART` | S | — | U | — |
| 103 | `DISABLE_BLE_UART` | S | `DISABLE_BLE_UART` | S | [W5](#whoop-5mg) |
| 104 | — | U | — | U | — |
| 105 | — | U | `TOGGLE_IMU_MODE_HISTORICAL` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 106 | `SET_IMU_DATA_STREAM` | S | `TOGGLE_IMU_MODE` | S | [W4](#whoop-4) · [W5](PROTOCOL_CONFIGURATION.md) |
| 107 | `GET_IMU_DATA_STREAM` | S | `ENABLE_OPTICAL_DATA` | S | [W4](#whoop-4) · [W5](PROTOCOL_CONFIGURATION.md) |
| 108 | — | U | `TOGGLE_OPTICAL_MODE` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 109 | — | U | — | U | — |
| 110 | — | U | — | U | — |
| 111 | — | U | — | U | — |
| 112 | — | U | — | U | — |
| 113 | — | U | — | U | — |
| 114 | — | U | — | U | — |
| 115 | `START_DEVICE_CONFIG_KEY_EXCHANGE` | S | `START_DEVICE_CONFIG_KEY_EXCHANGE` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 116 | `SEND_NEXT_DEVICE_CONFIG` | S | `SEND_NEXT_DEVICE_CONFIG` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 117 | `START_FF_KEY_EXCHANGE` | S | `START_FF_KEY_EXCHANGE` | S | [W4](#whoop-4) · [W5](PROTOCOL_CONFIGURATION.md) |
| 118 | `SEND_NEXT_FF` | S | `SEND_NEXT_FF` | S | [W4](#whoop-4) · [W5](PROTOCOL_CONFIGURATION.md) |
| 119 | `SET_DEVICE_CONFIG_VALUE` | S | `SET_DEVICE_CONFIG_VALUE` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 120 | `SET_FF_VALUE` | S | `SET_FF_VALUE` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 121 | `GET_DEVICE_CONFIG_VALUE` | S | `GET_DEVICE_CONFIG_VALUE` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 122 | `STOP_HAPTICS` | P / U | `STOP_HAPTICS` | S | [W4](#whoop-4) · [W5](#whoop-5mg) |
| 123 | — | U | `SELECT_WRIST` | S | [W5](PROTOCOL_ECG.md) |
| 124 | — | U | `TOGGLE_LABRADOR_DATA_GENERATION` | S | [W5](PROTOCOL_ECG.md) |
| 125 | — | U | `TOGGLE_LABRADOR_RAW_SAVE` | S | [W5](PROTOCOL_ECG.md) |
| 126 | — | U | `Send raw ECG` | S | [W5](PROTOCOL_ECG.md) |
| 127 | — | U | `Save filtered ECG` | S | [W5](PROTOCOL_ECG.md) |
| 128 | `GET_FF_VALUE` | S | `GET_FF_VALUE` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 129 | `SET_R12_REALTIME_STREAM` | S | — | U | — |
| 130 | `GET_R12_REALTIME_STREAM` | S | — | U | — |
| 131 | `SET_SEND_R19_PACKETS` | S | — | U | — |
| 132 | `GET_SEND_R19_PACKETS` | S | — | U | — |
| 133 | — | ? | — | U | — |
| 134 | — | ? | — | U | — |
| 135 | — | ? | — | U | — |
| 136 | — | ? | — | U | — |
| 137 | — | ? | — | U | — |
| 138 | — | ? | `SET_SIGNAL_PROCESSING_CONFIGURATION` | S | [W5](#ordinary-service-commands) |
| 139 | — | ? | `TOGGLE_LABRADOR_FILTERED` | S | [W5](PROTOCOL_ECG.md) |
| 140 | — | ? | `SET_ADVERTISING_NAME` | S | [W5](#ordinary-service-commands) |
| 141 | — | ? | `GET_ADVERTISING_NAME` | S | [W5](#ordinary-service-commands) |
| 142 | — | ? | `START_FIRMWARE_LOAD_NEW` | S | [W5](PROTOCOL_UPDATES.md#image-transfer-command-boundaries) |
| 143 | — | ? | `LOAD_FIRMWARE_DATA_NEW` | S | [W5](PROTOCOL_UPDATES.md#image-transfer-command-boundaries) |
| 144 | — | ? | `PROCESS_FIRMWARE_IMAGE_NEW` | S | [W5](PROTOCOL_UPDATES.md#image-transfer-command-boundaries) |
| 145 | — | ? | `GET_HELLO` | S | [W5](#whoop-5mg) |
| 146 | — | ? | `SET_CLOCK` | S | [W5](#whoop-5mg) |
| 147 | — | ? | `GET_CLOCK` | S | [W5](#whoop-5mg) |
| 148 | — | ? | `SET_WEAR_DETECTION_OVERRIDE` | S | [W5](#ordinary-service-commands) |
| 149 | — | ? | `SET_LED_ACCESSIBILITY` | S | [W5](#ordinary-service-commands) |
| 150 | — | ? | `Set gyro mode` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 151 | — | ? | `GET_BATTERY_PACK_INFO` | S | [W5](PROTOCOL_TRANSPORT.md#battery-pack--command-151) |
| 152 | — | ? | `Get gyro mode status` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 153 | — | ? | `TOGGLE_PERSISTENT_R20` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 154 | — | ? | `TOGGLE_PERSISTENT_R21` | S | [W5](PROTOCOL_CONFIGURATION.md) |
| 155 | — | ? | `START_CERTIFICATE_TRANSFER` | S | [W5](PROTOCOL_UPDATES.md#certificate-command-boundaries) |
| 156 | — | ? | `LOAD_CERTIFICATE` | S | [W5](PROTOCOL_UPDATES.md#certificate-command-boundaries) |
| 157 | — | ? | `VERIFY_CERTIFICATE` | S | [W5](PROTOCOL_UPDATES.md#certificate-command-boundaries) |
| 158 | — | ? | `PROCESS_CERTIFICATE` | S | [W5](PROTOCOL_UPDATES.md#certificate-command-boundaries) |
| 159 | — | ? | `LOCK_DEVICE` | S | [W5](PROTOCOL_UPDATES.md#certificate-command-boundaries) |

## Unsupported and cross-version commands

The U classification is version/context specific. For WHOOP 5/MG 50.42.1.0, the 88 `U` commands return result 3. Older family meanings or partial observations
do not add a command to the documented set. The legacy image-transfer,
analog-setting and advertising-name families likewise must not be used as aliases
for supported high-number commands. A result-3 reply is distinct from a timeout,
malformed-frame rejection or known command returning failure. Neither ID adjacency
nor a familiar enum name is a basis for probing a replacement.

<a id="whoop-4-command-profile"></a>

<a id="whoop-4-contracts"></a>

## WHOOP 4

The wire command byte is at frame offset 6 in a type-35 WHOOP 4 inner record.
Requests below exclude the outer envelope. Observed compatibility behavior is not
promoted to version-specific firmware support. Response offsets and result caveats are in the
[WHOOP 4 transport profile](PROTOCOL_TRANSPORT.md#whoop-4).

| ID | WHOOP 4 request/body | Response, effect and lifecycle | Validation and limit |
|---:|---|---|---|
| 1, 2, 4, 5 | no request documented | No observation is recorded for this version. | **U · outside the documented 41.17.6.0 command set.** |
| 3 | `00` off / `01` on in a request form observed in use | Sent by NOOP; no proprietary type-40 transition has been observed for this version. The standard BLE Heart Rate Service is separate. | **P / U · implemented outside the documented 41.17.6.0 command set.** |
| 7 | empty or legacy default | The 68-byte response body has revision 1 at offset 0, four Harvard `u32le` version components at 1, four Boylston components at 17, then 35 not-yet-named bytes. | **S · documented for 41.17.6.0.** |
| 10 | request forms observed in use: `seconds:u32le` plus four or five zeros | On some devices one of the two SET_CLOCK forms was observed to latch; read back to confirm. | **O / U · observed outside the documented 41.17.6.0 command set.** |
| 11 | request forms observed in use: empty or `00` | Use the form accepted by the device and read back the clock rather than inferring it from write acknowledgement. | **O / U · observed outside the documented 41.17.6.0 command set.** |
| 19 | exact request body unresolved | `SET_R7_REALTIME_STREAM`; this is not a haptic operation. | **S · 41.17.6.0.** Accepted options, response body and packet-transition timing remain unresolved; WHOOP 5/MG reuses ID 19 for `RUN_HAPTIC_PATTERN_MAVERICK`. |
| 20 | `00` | Aborts an open offload without acknowledging or trimming its uncommitted chunk. | **O / U · observed working in device captures on 41.17.6.0, outside the documented command set.** Restart position remains unresolved. |
| 22 | `00` | Starts asynchronous type-47 historical delivery; a response is not the data stream. | **O / U · observed working in device captures on 41.17.6.0, outside the documented command set.** Type-47 delivery was observed. |
| 23 | `01` plus exact eight-byte `HISTORY_END` block | Consumer ACK after durable commit; may permit history reclamation. | **O / U · observed working in device captures on 41.17.6.0, outside the documented command set.** `HISTORY_END` acknowledgement was observed; never reconstruct the opaque second word. |
| 26 | `00` or empty | Final charge value is `u16le / 10` percent; also used as the confirmed connection write. | **S · observed in device captures; supported by NOOP.** Validate result and body length before use. |
| 29 | no semantic fields; empty, `00` and `01` are equivalent | Returns result 1 without a body; a reboot follows. | **S · documented for 41.17.6.0.** One device observation showed no visible reboot, so the physical effect is not yet confirmed. |
| 32 | no semantic fields; empty, `00` and `01` are equivalent | Returns result 1 without a body; a power cycle follows (distinct from 29). | **S · documented for 41.17.6.0.** The physical effect remains separate from response acceptance. |
| 34 | `00` | Responses may advance response sequence while echoing one request origin. | **S · observed in device captures.** The body is not the 65-byte 50.42.1.0 layout. |
| 35 | `00` | The 131-byte body has a 10-byte serial field at body offset 14 (nine serial bytes plus NUL) and 54 bytes of key and signature material at 24. | **S · documented for this version; observed in device captures.** Sensitive material must never be exposed. |
| 63 | `00` off / `01` on | Controls the type-43 R10/R11 realtime output; 82 is not an alias. | **S · observed in device captures.** WHOOP 5/MG 50.42.1.0 returns result 3 for this ID. |
| 66 | `01 \|\| epoch_seconds:u32le \|\| subseconds:u16le` | Arms a WHOOP 4 alarm; storage acknowledgement and physical wake are separate. Working observed requests appended two zero bytes that are not evaluated. | **S · documented for 41.17.6.0; observed in device captures.** A seven-byte request was acknowledged without vibration; the semantic distinction is the subsecond field, not a longer body contract. |
| 67 | `[01]` | Reads legacy alarm state. | **S · observed in device captures; supported by NOOP.** Failure/readback variants are not exhaustive. |
| 68 | `[01]` | Starts immediate legacy alarm/haptic execution. | **S · observed in device captures; supported by NOOP.** Acceptance is not motor-movement proof. |
| 69 | `[01]` | Disables the legacy alarm, distinct from stopping an active haptic. | **S · observed in device captures; supported by NOOP.** Readback and reboot persistence remain bounded. |
| 76 | `00` | Reads the Harvard advertising name. | **S · documented for 41.17.6.0.** Complete response-field validation remains incomplete. |
| 77 | two reserved bytes, then a 16-byte name field | The first name byte must be nonzero; the last field byte is forced to NUL, leaving at most 15 name bytes. Bytes are not validated as UTF-8. | **S · documented for 41.17.6.0.** Visibility after a write is not yet confirmed in device captures. |
| 79 | five-byte preset request | Runs a legacy preset haptic pattern. | **S · observed in device captures.** Not the WHOOP 5/MG revision-1 12-byte notification pattern. |
| 81 | `[01]` | Starts WHOOP 4 raw-data output, separate from stream 63. | **S · supported by NOOP; effect not yet confirmed.** |
| 82 | `[01]` | Stops raw-data output; does not select R10/R11 stream 63. | **S · supported by NOOP; effect not yet confirmed.** Full sensor shutdown is not established. |
| 84 | legacy read request | Response fields are revision/location/confidence/status. | **S · observed in device captures.** Do not substitute the 50.42.1.0 fixed cached-status placeholders. |
| 96 | `revision_or_legacy:u8 \|\| period:u16le \|\| duration:u16le` | Enables high-frequency sync; period is at least 60 seconds and duration is at most 28,800 seconds. Returns result 1 without a body. | **S · documented for 41.17.6.0.** Event 97 reports enabled state. |
| 97 | no semantic request fields | Disables high-frequency sync and returns result 1 without a body. | **S · documented for 41.17.6.0.** Event 98 reports disabled state. |
| 98 | legacy read | With a valid cache, result 1 carries 25 bytes: `u8`, seven `u16le`, two `u32le`, then `u16le`; pack millivolts are the third `u16le` at body offset 5. | **S · documented for 41.17.6.0.** An empty cache returns result 0; this is not WHOOP 5/MG command 151. |
| 106 | `[01, state]`, where state is 0 or 1 | Sets the stored IMU data-stream state. | **S · documented for 41.17.6.0.** |
| 107 | `[01]` | Returns the stored IMU data-stream state. | **S · documented for 41.17.6.0.** The WHOOP 5/MG identifier `ENABLE_OPTICAL_DATA` does not describe this WHOOP 4 operation. |
| 117 | `[01]` | Starts feature-name enumeration and returns bounded enumeration state/count. | **S · observed in a named 41.16.6.0 device capture.** Names/layout are firmware-bound and do not establish values. |
| 118 | `[01]` repeated as cursor step | Advances feature-name enumeration; it is not an arbitrary index read. | **S · observed in a named 41.16.6.0 device capture.** End marker, exact key set and other releases remain bounded. |
| 122 | `[00]` | Stops an in-progress legacy haptic request. | **P / U · implemented outside the documented 41.17.6.0 command set.** Does not prove the WHOOP 5/MG pending/final revision-1 lifecycle. |
| 105, 123 | no request documented | No observation is recorded for this version. The wrist-selection meaning of 123 belongs to WHOOP 5/MG ECG. | **U · outside the documented 41.17.6.0 command set.** |

### Version boundaries and negative space

WHOOP 4 command contracts combine supported behavior and version-labelled
observations. A request, an acknowledgement and a physical effect remain
separate facts. Commands 10/11, 20, 22/23 and 122 are outside the documented
41.17.6.0 command set; their combined `O / U` or `P / U` status records observations
or implementation outside that set. Commands 20, 22 and 23 were observed working
in device captures on 41.17.6.0, including type-47 delivery and `HISTORY_END`
acknowledgement. On some devices one of the two SET_CLOCK forms was observed to
latch; read back to confirm. Commands 1, 2, 4, 5, 105 and 123 are not documented
for this version and have no recorded observation. The ECG wrist-selection meaning
of 123 belongs to WHOOP 5/MG. A WHOOP 5/MG result says nothing about the same
numeric ID on WHOOP 4.

<a id="whoop-5mg-contracts"></a>
<a id="core-command-contracts"></a>

## WHOOP 5/MG

| Operation | Request and response | Effect / limits |
|---|---|---|
| Link check | No semantic payload fields; success, fixed 13-byte NUL-terminated acknowledgement. | Link-level acknowledgement, not device identity. |
| Live HR | An older request uses byte `0` off / `1` on. | Live HR delivery is distinct from the command response; current acceptance and complete prerequisites unresolved. |
| Generic HR profile | One byte `0`/`1`; others fail. Success or failure with empty body, according to setting-write result. | Updates a nonvolatile policy; subsequent standard-GATT behavior and observed restart survival unresolved. |
| Event delivery | One byte `0`/`1`; others fail; accepted request returns success with empty body. | Delivery toggle. Whether it selects historical events, future events or both remains unresolved; “flush stored events” is not established. |
| High-frequency sync entry | Revision 2, period `u16le`, duration `u16le`; period strictly greater than 60, duration strictly less than 28,800. | Accepted request returns success empty; invalid values fail empty. Duration is in seconds; the periodic event repeats at approximately the configured period. [Scheduler contract](#high-frequency-sync-scheduler). |
| High-frequency sync exit | No semantic payload fields; success empty precedes queued disable. | Explicit exit clears active and emits event 98; automatic expiry differs. [Scheduler contract](#high-frequency-sync-scheduler). |
| History request / abort | Older requests use explicit `00` for each operation. | Start delivers metadata/records asynchronously; abort is not trim. Command 22 returns state plus two zero bytes; states 6/7/9/10 fail and others succeed, while asynchronous work is still requested. Delivery is separate. |
| History acknowledgement | `01` plus the eight original HISTORY_END bytes, only after local commit. | May release stored device history. See [storage ownership](PROTOCOL_TRANSPORT.md#history-sequencing-and-storage-ownership). |
| Range | No semantic request fields; initial pending empty. | Final body is 65 bytes with page cursors, estimates and clock pairs; see [range fields](PROTOCOL_TRANSPORT.md#data-range--command-34). An earlier MG returned pending then success; do not generalize all older offsets. |
| Battery | Older requests use empty or `00`; current query is asynchronous with no immediate reply established. | Older WHOOP 4 charge is `u16le / 10` percent; an older WHOOP 5 observation identified the first body byte as whole percent without establishing a universal one-byte body. The current final body is u32 whole percent; zero can be a conversion substitute. An error reply carries four zero bytes; a measurement timeout is not confirmed to produce that reply (see [battery responses](PROTOCOL_TRANSPORT.md#battery-level--command-26)). |
| Deprecated clock SET/GET | Historical SET: seconds `u32le` plus four zero subsecond bytes; WHOOP 4 also has a ninth zero variant. GET uses empty or `00`. | Current payload/reply unresolved. Separate from revision-1 high-number clocks. |
| Legacy Hello | The WHOOP 4 request uses `00`. | No command reply is documented for 50.42.1.0; do not expose identity fields unnecessarily. |
| New Hello and clock pair | [Exact revision, size and clock precision contracts](PROTOCOL_TRANSPORT.md#clock-and-identity-contracts). | Hello final bodies are 107/111 bytes; retain their preparation flags; clock success alone does not prove nonzero valid time. |

### High-frequency sync scheduler

Command 96 revision 2 carries revision `2`, period u16le at byte 1 and duration
u16le at byte 3. Accepted values are period >60 and duration <28800. Duration is
in seconds and is compared against wall-clock seconds. The period unit is
nominally about one second, so period 61 corresponds to roughly 61 seconds of
elapsed periodic interval. Scheduling latency is not bounded here; this is not an
exact elapsed-time guarantee.
Entering while already active does not replace the period, duration or start
time. Do not treat its successful response as confirmation that a session was
refreshed.

First entry emits event 97 (`0x61`). While active, event 96 (`0x60`) repeats at
approximately the configured period. For periods 32768–65535 the periodic event
is not emitted at all. Entry and explicit exit do not reset the elapsed period,
so the first interval after an entry can be shorter than the configured one.

Command 97 emits event 98 (`0x62`) and clears active. Automatic duration expiry
clears active without that exit event. Duration zero expires at the next periodic
scan, after the periodic-event check. Wall-clock changes and 32-bit deadline
arithmetic matter; elapsed time is measured against the wall clock, not an
independent elapsed-time counter.
These paths schedule event notifications; they do not establish faster Bluetooth
transfer or a changed acquisition rate. Further event consumers or client
reactions are outside this contract. Keep command IDs and event IDs in separate
namespaces.

### Haptics and alarms

Notification haptics uses a revision-1, 12-byte body: revision at 0, eight waveform-effect bytes at 1–8, effect loop-control `u16le` at 9–10, overall-repeat byte at 11. Observed requests use effect-loop control zero. The overall field counts repetitions **after the first pulse**, so a request for N pulses uses N−1. Older MG validation found four buzzes when that byte was 3. The documented supported range of one through eight pulses is an application bound, not a universal firmware maximum. The current WHOOP 5/MG validation requires each of the eight effect bytes to be at most 251 and the overall-repeat byte to be below 8. It does not validate the loop-control field. Passing these checks alone does not establish a valid physical waveform. A retained effect sequence and its attribution are recorded on the [implementation page](PROTOCOL_IMPLEMENTATION.md#6-commandnumber-sending--the-safe-subset); these fields do not establish every possible waveform ID.

Alarm SET/GET, validation, readback, single/all-ID disable and manual RUN are described in
[alarm configuration and execution](PROTOCOL_ALARMS.md). The current record is 21 bytes,
including crescendo; the earlier 20-byte record obtains crescendo zero from framing
padding and is not thereby shown to be a short frame. SET validation detail, storage
result, execution event and physical wake are separate outcomes. RUN consumes its selected
saved schedule and is not a guaranteed nondestructive preview.

STOP_HAPTICS takes revision 1 alone and returns pending then a final result, each with body `[1]`. Stopping a buzz does not prove that a scheduled alarm was removed.
Older alarm arming acknowledgements remain scoped to their runs; no successful physical
wake is claimed. Haptic actions belong to deliberate app actions, not connection
discovery.

### Service and sensitive operations

Pairing reset and reboot interrupt connection and work; preservation is not established for every operation. Forced trim and read-pointer changes mutate history ownership and cannot substitute for committed-chunk acknowledgement. Their recovery behavior remains unresolved. Battery-pack fields are in [transport](PROTOCOL_TRANSPORT.md#battery-pack--command-151).

### Ordinary service commands

The following operation-specific schemas are for independent interface implementations. A known field does not establish every prerequisite, safe operating sequence or completed effect. These fields do not authorize or describe a tested device update.

All service-table offsets are command-body offsets; integers are little-endian. Revisioned operations use revision 1. Outer result is 1 success / 0 failure, separate from the listed body. Semantic lengths do not establish acceptance of unpadded short frames.

| Command | Request body | Response body | Behavior |
|---:|---|---|---|
| 148 | `revision:u8=1, override:u8` | `[1]` | `override=1` forces the worn state and disables normal wear detection. `0` restores normal detection. Other values fail. Restoring detection does not promise an immediate off-body report. |
| 149 | `revision:u8=1, enabled:u8` | `[1]` | Sets the persistent LED accessibility option; accepts only 0 and 1. Success reports the settings write result. Exact visual patterns depend on the indicator state. |
| 140 | `revision:u8=1, length:u8, name[length]` | `[1]` | Stores an advertising name of 0–15 bytes and requests an advertising update. Length counts bytes. No character-set validation is established. Radio visibility and client cache refresh may lag the reply. |
| 141 | `revision:u8=1` | Fixed 19 bytes, described below | Reads the advertising name. |
| 84 | `revision:u8=1` | `[1, 0, 255, on_body]` | Returns cached on-body status, 0 or 1. The two middle bytes are fixed placeholders, not measured location or confidence. |
| 138 | `revision:u8=1, selector:u8` | Empty | Selectors 0–8 select defined presets whose meanings remain undocumented. Every byte value receives success for revision 1; values 9–255 do not select a new preset. Success does not confirm persistence. |
| 103 | `revision:u8=1` | `[1]` | Acknowledges a BLE UART disable request before its asynchronous handling. No enable argument or completion/readback contract is established. |
| 32 | No command fields established | Empty | Acknowledges a power-cycle request before asynchronous lifecycle handling. Completion delay, power-rail behavior and retained state are not established. |

For the revisioned commands, an unsupported revision fails. Command 138 has an empty failure body. Commands 84 and 141 return their initialized fixed-size bodies on revision failure: `[1,0,0,0]` and `[1]` followed by 18 zeros. The remaining one-byte ordinary responses retain `[1]` on failure.

Command 149 updates one option within a shared stored settings record. If reading that record fails, it starts from defaults before writing the requested option. Success therefore does not prove that the other previously stored options were preserved.

Command 141 returns revision 1 at offset 0; source/status at offset 1; a NUL-inclusive length of 1–16 at offset 2; and 16 bytes of name storage at offsets 3–18. Status 1 identifies a custom name. Status 2 covers fallback or empty storage and storage-read failure; it does not diagnose a specific storage error. The last storage byte is zero. Limit decoding to this fixed storage and exclude the terminator from display.

<a id="image-transfer-command-boundaries"></a>
<a id="certificate-command-boundaries"></a>

### Image-transfer and certificate commands

Commands 83 and 142–144 transfer and verify a firmware image; their request bodies,
response details and container fields are specified in
[image transfer](PROTOCOL_UPDATES.md#image-transfer-command-boundaries). Commands
155–159 cover certificate transfer and device authorization; NOOP implements no
update or unlock path, and the details are outside this reference. See
[certificates and authorization](PROTOCOL_UPDATES.md#certificate-command-boundaries).
