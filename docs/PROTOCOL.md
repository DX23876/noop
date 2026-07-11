# WHOOP BLE Protocol

This document specifies the Bluetooth Low Energy (BLE) wire protocol that NOOP uses to talk
**directly to a WHOOP strap you own** (4.0 and 5.0/MG). It is a reverse-engineering reference:
frame envelope, checksums, packet/command/event enumerations, the bond handshake, and the
historical-data offload state machine.

NOOP is a standalone, fully offline companion. It pairs over BLE, decodes the strap's own
streams on-device, and stores everything locally in SQLite. There is no cloud or account
involved in any of the exchanges described here.

> **Interoperability & safety note.** This describes interoperation with the user's *own*
> device and the data it already holds. NOOP is **not affiliated with, authorized by, or
> endorsed by WHOOP**, and it is **not a medical device** — nothing here is intended for
> diagnosis or treatment. The command set NOOP sends is deliberately a *safe subset*;
> destructive opcodes are documented only so they can be explicitly avoided
> (see [Destructive commands — do not send](#destructive-commands--do-not-send)).

The protocol decoder is platform-pure Swift in the `WhoopProtocol` package
(`Packages/WhoopProtocol/`); it never imports CoreBluetooth, so it runs unchanged in tests and
CLI tools. The CoreBluetooth transport lives under `Strand/BLE/` and is shared by both the
macOS and iOS app targets (the platform-pure `WhoopProtocol` package above stays
CoreBluetooth-free for tests and CLI tools).

This work builds on two community reverse-engineering efforts:

- **`johnmiddleton12/my-whoop`** — WHOOP 4.0 protocol.
- **`b-nnett/goose`** — WHOOP 5.0 ("puffin") protocol.

The canonical decode tables are bundled as a JSON resource:
`Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json`, loaded by
`loadSchema()` in `Schema.swift`.

---

## 1. GATT topology

Each WHOOP generation advertises a vendor-specific primary service plus the two standard SIG
services (Heart Rate and Battery). The custom service carries the framed command/response/
event/data channels; the standard services work even before bonding.

### WHOOP 4.0 — service `61080001-…`

Defined in `BLEManager.swift` (the on-device, authoritative UUIDs) and mirrored as plain
strings in `DeviceFamily.swift`. The same `Strand/BLE/` sources (`BLEManager`,
`StandardHeartRate`, `FrameRouter`) back both Apple-platform targets — macOS and iOS.

| Role | UUID | Direction |
|------|------|-----------|
| Custom service | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | — |
| Command write (`cmdWriteChar`) | `61080002-8d6d-82b8-614a-1c8cb0f8dcc6` | app → strap |
| Command-response notify (`cmdNotifyChar`) | `61080003-8d6d-82b8-614a-1c8cb0f8dcc6` | strap → app |
| Event notify (`eventNotifyChar`) | `61080004-8d6d-82b8-614a-1c8cb0f8dcc6` | strap → app |
| Data notify (`dataNotifyChar`, fragmented) | `61080005-8d6d-82b8-614a-1c8cb0f8dcc6` | strap → app |

### WHOOP 5.0 / MG — service `fd4b0001-…`

The 5.0 transport ("puffin") adds a fifth characteristic (`…0007`). UUID strings are in
`DeviceFamily.characteristicUUIDStrings`.

| Role | UUID |
|------|------|
| Custom service | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Command write | `fd4b0002-cce1-4033-93ce-002d5875f58a` |
| Notify channels | `fd4b0003`, `fd4b0004`, `fd4b0005`, `fd4b0007` (`…-cce1-4033-93ce-002d5875f58a`) |

### Standard SIG services (both generations)

| Service | UUID | Characteristic | UUID | Notes |
|---------|------|----------------|------|-------|
| Heart Rate | `180D` | HR Measurement | `2A37` | HR + R-R; works **unbonded** |
| Battery | `180F` | Battery Level | `2A19` | single byte = battery percent |

The `0x2A37` channel is the BLE-standard Heart Rate Measurement and is parsed by the pure
`StandardHeartRate.parse(_:)` (`Strand/BLE/StandardHeartRate.swift`): flag byte, 8- or 16-bit
HR, optional Energy-Expended skip, then R-R intervals in 1/1024 s converted to milliseconds.
NOOP treats this as the *reliable* HR/R-R source (the custom `REALTIME_DATA` stream usually
reports `rr_count = 0`). `0x2A19` is read as a raw percent (`state.setBattery(Double(pct))`).

`DeviceFamily` keeps CoreBluetooth out of the protocol package: it exposes UUIDs as **strings**;
the app layer wraps them in `CBUUID(string:)`.

---

## 2. Frame envelope

A frame is a self-delimiting byte string beginning with a Start-Of-Frame marker and ending with
a CRC32 trailer. The two generations share the CRC32 payload check but differ in the header
checksum. The branch point is `DeviceFamily.headerCRCKind`:

| Family | Header check | Enum (`HeaderCRCKind`) |
|--------|--------------|------------------------|
| `whoop4` | CRC8 (poly `0x07`) | `.crc8` |
| `whoop5` | CRC16-Modbus (poly `0xA001`, init `0xFFFF`, reflected) | `.crc16Modbus` |

### 2.1 WHOOP 4.0 envelope

```
┌──────┬───────────────┬───────┬───────────── inner ─────────────┬─────────────┐
│ 0xAA │ length  u16 LE │ crc8  │ type │ seq │ cmd │  payload …    │ crc32 u32 LE│
│ [0]  │ [1..3]         │ [3]   │ [4]  │ [5] │ [6] │ [7 .. len)    │ [len .. +4) │
└──────┴───────────────┴───────┴───────────────────────────────────┴────────────┘
total frame size = length + 4
```

- **`0xAA`** — Start Of Frame.
- **`length`** — `u16` little-endian. Equals `inner.count + 4` (the inner `[type][seq][cmd]
  payload]` plus the 4 envelope bytes). It is the offset at which the CRC32 trailer begins.
- **`crc8`** — CRC8 (table-driven, poly `0x07`) computed over the **two length bytes only**
  (`crc8([frame[1], frame[2]])`).
- **inner record** — `type` (packet type, §3), `seq` (sequence / version byte), `cmd`
  (command number, §6), then the payload.
- **`crc32`** — standard zlib CRC-32 (reflected, poly `0xEDB88320`), `u32` little-endian,
  computed over the **inner bytes** `frame[4 .. length)`.

Reference: `verifyFrame(_:)` and `crc8(_:)` / `crc32(_:)` in `Framing.swift`, and the
outbound builder `WhoopCommand.frame(seq:payload:)` in `Strand/BLE/Commands.swift`.

```swift
// Framing.swift — WHOOP 4.0 validation (abridged)
let length = u16le(frame, 1)
let crc8OK = crc8([frame[1], frame[2]]) == frame[3]
if 7 <= length && length + 4 <= frame.count {
    let inner = Array(frame[4..<length])
    crc32OK = crc32(inner) == u32le(frame, length)
}
```

### 2.2 WHOOP 5.0 / MG envelope

The 5.0 envelope (reverse-engineered from `goose`) inserts a format byte and a CRC16-Modbus
header check, and shifts the inner record to offset 8:

```
┌──────┬────────┬──────────────────┬────────────┬───────────────┬──── inner ────┬─────────────┐
│ 0xAA │ format │ declLength u16 LE│ header [2] │ crc16 u16 LE  │ type seq cmd …│ crc32 u32 LE│
│ [0]  │ [1]    │ [2..4]           │ [4..6]     │ [6..8]        │ [8 ..]        │ tail (4)    │
└──────┴────────┴──────────────────┴────────────┴───────────────┴───────────────┴─────────────┘
total frame size = declLength + 8
```

- **`format`** — `0x01`.
- **`declLength`** — `u16` LE; counts the payload **plus** the 4-byte CRC32 trailer
  (so payload length = `declLength − 4`, and the trailer starts at `declLength + 8 − 4`).
- **`crc16`** — CRC16-Modbus over the first **6** header bytes (`frame[0..<6]`), stored LE at
  `frame[6..8]`.
- **inner record** — starts at **offset 8**: `type` `[8]`, `seq` `[9]`, `cmd` `[10]`, payload `[11..]`.
- **`crc32`** — same zlib CRC-32, LE, over the payload `frame[8 .. declLength+4)`.

Reference: `verifyFrameWhoop5(_:)` / `parseFrameWhoop5(_:)`. For a uniform "header CRC ok?"
signal across families, the `FrameCheck.crc8OK` field carries the **CRC16** outcome on 5.0.

The static WHOOP 5.0 `CLIENT_HELLO` (16 bytes, a fully-formed type-35 frame with CRC16 header
and CRC32 trailer) is `DeviceFamily.whoop5ClientHello`:

```
AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D
```

WHOOP 4.0 has **no** fixed hello (`clientHello == nil`); it uses the bond-write handshake (§5).

### 2.3 Family-aware entry points

```swift
public func verifyFrame(_ frame: [UInt8], family: DeviceFamily) -> FrameCheck
public func parseFrame(_ frame: [UInt8], family: DeviceFamily) -> ParsedFrame
```

`whoop4` behaves exactly like the no-family overloads (back-compat). The "puffin" types
`38 PUFFIN_COMMAND_RESPONSE` and `56 PUFFIN_METADATA` are aliased onto `COMMAND_RESPONSE` /
`METADATA` by `canonicalTypeName(_:schema:)` so they never decode as "unknown".

### 2.4 Checksums

| Algorithm | Function | Parameters |
|-----------|----------|------------|
| CRC8 | `crc8(_:)` | table-driven, poly `0x07`, init `0x00` |
| CRC32 (zlib) | `crc32(_:)` | reflected, poly `0xEDB88320`, init `0xFFFFFFFF`, final XOR `0xFFFFFFFF` |
| CRC16-Modbus | `crc16Modbus(_:)` | poly `0xA001`, init `0xFFFF`, reflected |

CRC32 is the protocol's **only payload-integrity guarantee**. Decode and state-update paths
reject any frame whose CRC32 fails: `FrameRouter.handle(frame:)` bails on `parsed.crcOK == false`,
and `classifyHistoricalMeta(_:)` refuses to act on a frame where `p.crcOK == false` — without
that gate a garbled or hostile peer could forge a `HISTORY_END`/`HISTORY_COMPLETE` and advance
the strap's trim cursor, discarding data that was never durably stored.

### 2.5 Reassembly

BLE notifications arrive as MTU-sized fragments. `Reassembler` (`Framing.swift`) accumulates
bytes, finds the `0xAA` SOF, reads the `u16` LE length at `buf[1..3]`, and emits a complete
frame once `buf.count ≥ length + 4`. Leading garbage before an SOF is discarded; a buffer with
no SOF is dropped. The app feeds the data/cmd/event notify characteristics through one
`Reassembler` in `peripheral(_:didUpdateValueFor:error:)`.

```swift
// usage in BLEManager
for frame in reassembler.feed(bytes) {
    router.handle(frame: frame)   // UI/state
    // … live ingest or backfill routing …
}
```

`frameFromPayload(_:type:seq:cmd:)` reconstructs a complete frame from a bare payload (used when
a capture stored only the data portion): it rebuilds the envelope with a correct zlib CRC32 and
a placeholder `0x00` CRC8 byte.

---

## 3. PacketType (offset `[4]`, or `[8]` on 5.0)

Source: `enums.PacketType` in `whoop_protocol.json`; resolved by `Schema.typeName(_:)`.

| Value | Name | Notes |
|------:|------|-------|
| 35 | `COMMAND` | outbound command (app → strap) |
| 36 | `COMMAND_RESPONSE` | reply to a command |
| 37 | `PUFFIN_COMMAND` | WHOOP 5.0 command |
| 38 | `PUFFIN_COMMAND_RESPONSE` | WHOOP 5.0; aliased → `COMMAND_RESPONSE` |
| 40 | `REALTIME_DATA` | live HR / R-R |
| 43 | `REALTIME_RAW_DATA` | live IMU/optical flood (~2/s, ~1.9 KB) |
| 47 | `HISTORICAL_DATA` | offloaded biometric records |
| 48 | `EVENT` | strap event (§4) |
| 49 | `METADATA` | offload control metadata (§7) |
| 50 | `CONSOLE_LOGS` | firmware log text |
| 51 | `REALTIME_IMU_DATA_STREAM` | |
| 52 | `HISTORICAL_IMU_DATA_STREAM` | |
| 53 | `RELATIVE_PUFFIN_EVENTS` | WHOOP 5.0 |
| 54 | `PUFFIN_EVENTS_FROM_STRAP` | WHOOP 5.0 |
| 55 | `RELATIVE_BATTERY_PACK_CONSOLE_LOGS` | |
| 56 | `PUFFIN_METADATA` | WHOOP 5.0; aliased → `METADATA` |

`isOffloadFrame(_:)` (in `BLEManager`) treats **47/48/49/50** as offload traffic; the live
`REALTIME_DATA`(40)/`REALTIME_RAW_DATA`(43) flood is excluded so it cannot keep the backfill
idle-watchdog alive.

The parser also exposes irregular fields through per-type **post-hooks**
(`registerPostHooks()` in `PostHooks.swift`): `realtime_data`, `event`, `command_response`,
`raw_data`, `historical_data`, `metadata`, `console_logs`. The static field layout per packet
comes from the schema's `packets` table; `REALTIME_RAW_DATA` is keyed by payload length
(`"1917"` = IMU, `"1921"` = optical), and `HISTORICAL_DATA` by its version byte (`seq`).

---

## 4. EventNumber (`EVENT`, type 48, value at `[6]`)

`EVENT` frames carry an `EventNumber` at `[6]` and a `u32` `event_timestamp` at `[8]`. A
strap-pushed event is WHOOP's "strap-as-clock" signal: NOOP treats any event as "I may have new
data" and kicks a rate-limited sync (`FrameRouter.onSyncTrigger` → `requestSync(.strap)`).
Selected, frequently-used values (full table in `whoop_protocol.json`):

| Value | Name | | Value | Name |
|------:|------|-|------:|------|
| 3 | `BATTERY_LEVEL` | | 42 | `ACCELEROMETER_SATURATION_DETECTED` |
| 7 | `CHARGING_ON` | | 46 | `RAW_DATA_COLLECTION_ON` |
| 8 | `CHARGING_OFF` | | 47 | `RAW_DATA_COLLECTION_OFF` |
| 9 | `WRIST_ON` | | 56 | `STRAP_DRIVEN_ALARM_SET` |
| 10 | `WRIST_OFF` | | 57 | `STRAP_DRIVEN_ALARM_EXECUTED` |
| 13 | `RTC_LOST` | | 58 | `APP_DRIVEN_ALARM_EXECUTED` |
| 14 | `DOUBLE_TAP` | | 59 | `STRAP_DRIVEN_ALARM_DISABLED` |
| 17 | `TEMPERATURE_LEVEL` | | 60 | `HAPTICS_FIRED` |
| 23 | `BLE_BONDED` | | 63 | `EXTENDED_BATTERY_INFORMATION` |
| 32 | `CAPTOUCH_AUTOTHRESHOLD_ACTION` | | 96 | `HIGH_FREQ_SYNC_PROMPT` |
| 33 | `BLE_REALTIME_HR_ON` | | 97 | `HIGH_FREQ_SYNC_ENABLED` |
| 34 | `BLE_REALTIME_HR_OFF` | | 98 | `HIGH_FREQ_SYNC_DISABLED` |
| 40 | `CH1_SATURATION_DETECTED` | | 100 | `HAPTICS_TERMINATED` |
| 41 | `CH2_SATURATION_DETECTED` | | | |

`FrameRouter` maps several physical events to UI callbacks: `BLE_BONDED` confirms bonding,
`DOUBLE_TAP` fires `onDoubleTap`, `WRIST_ON`/`WRIST_OFF` toggle `worn` and fire `onWristChange`.
The `BATTERY_LEVEL` event has a fixed decoded layout (see the `event` post-hook):
`soc% = u16@17 / 10`, `mV = u16@21`, `charging = u8@26 & 1`.

---

## 5. Bond handshake & connect lifecycle (WHOOP 4.0)

The custom channels only flow once the link is bonded. CoreBluetooth performs *just-works*
bonding the moment a confirmed (`.withResponse`) write succeeds, so NOOP bonds by sending one
benign command and waiting for the write acknowledgement.

```
scan(service 61080001) ─▶ connect ─▶ discoverServices
                                       └▶ discoverCharacteristics
                                            ├ on cmdWriteChar (0002):
                                            │    confirmed write GET_BATTERY_LEVEL  ── THE BOND TRICK
                                            └ on 0003/0004/0005/2A37/2A19: setNotifyValue(true)
        confirmed-write ack (didWriteValueFor, no error) ─▶ BONDED  (state.bonded = true)
```

After bonding, the connect handshake runs **exactly once** per connection (guarded by
`connectHandshakeDone`, because `didWriteValueFor` re-fires on every later `.withResponse`
write). Re-blasting the handshake mid-offload was the historical root cause of the strap
refusing to stream type-47, so the guard is load-bearing. The one-shot handshake (in
`peripheral(_:didWriteValueFor:error:)`) issues, in order:

1. `GET_HELLO_HARVARD` (35) — version/identity hello (mirrors the official flow; not strictly
   required to serve).
2. `GET_ADVERTISING_NAME_HARVARD` (76).
3. `SET_CLOCK` (10) — set the strap RTC to UTC; payload is the **8-byte** form
   `[seconds u32 LE][subseconds u32 LE]` (`BLEManager.setClockPayload()`). A wrong-length
   `SET_CLOCK` is ack'd but not latched, leaving the RTC "lost" so the strap won't serve type-47.
4. `GET_CLOCK` (11) with an **empty** payload (the strap ignores a wrong-length payload). The
   response establishes the device↔wall `ClockRef` correlation used for realtime decode.
5. `SEND_R10_R11_REALTIME` (63) with `[0x00]` — stop the ~2/s type-43 raw flood (BLE airtime /
   battery / flash). This is the *real* control for that stream; `STOP_RAW_DATA` (82) does not
   affect it.
6. `GET_DATA_RANGE` (34) — refresh the strap's stored record range for the liveness watchdog.
7. After ~1.5 s (so the link settles), the first historical offload via `requestSync(.connect)`.

A periodic backfill timer (`backfillIntervalSeconds = 900`, i.e. 15 min, matching WHOOP) and a
keep-alive timer (`keepAliveIntervalSeconds = 30`: re-arm realtime, poll battery, watchdog the
link) are then started. The `GET_CLOCK` response is decoded by `ClockCorrelation` to produce a
`ClockRef(device:wall:)`; this unblocks both the live `Collector` and the `Backfiller`.

> WHOOP 5.0 instead writes the static `CLIENT_HELLO` frame (§2.2) to its `…0002` command
> characteristic immediately after discovery.

---

## 6. CommandNumber (sending) — the safe subset

NOOP exposes a curated, **safe** command set in `WhoopCommand` (`Strand/BLE/Commands.swift`).
The raw value is the on-wire command byte at `[6]` (inside a type-35 `COMMAND` frame). Commands
are built by `WhoopCommand.frame(seq:payload:)` and written to `…0002`.

```swift
public func frame(seq: UInt8, payload: [UInt8] = [0x00]) -> [UInt8] {
    let inner: [UInt8] = [35 /* COMMAND */, seq, rawValue] + payload
    let length = UInt16(inner.count + 4)
    let lenBytes: [UInt8] = [UInt8(length & 0xFF), UInt8(length >> 8)]
    return [0xAA] + lenBytes + [crc8(lenBytes)] + inner + crc32(inner) /* LE */
}
```

| Code | Command | Typical payload | Purpose |
|-----:|---------|-----------------|---------|
| 1 | `LINK_VALID` | — | link keep-alive |
| 3 | `TOGGLE_REALTIME_HR` | `[0x01]`/`[0x00]` | start/stop live HR stream (type-40) |
| 7 | `REPORT_VERSION_INFO` | — | firmware versions (decoded by `command_response` hook) |
| 10 | `SET_CLOCK` | `[secs u32 LE][subsecs u32 LE]` | set strap RTC (UTC) |
| 11 | `GET_CLOCK` | *empty* | read RTC → `ClockRef` correlation |
| 22 | `SEND_HISTORICAL_DATA` | `[0x00]` | begin offload of the type-47 store |
| 23 | `HISTORICAL_DATA_RESULT` | `[0x01] + end_data(8)` | ack a `HISTORY_END` chunk / advance trim |
| 26 | `GET_BATTERY_LEVEL` | `[0x00]` | battery percent; also the **bond** write |
| 34 | `GET_DATA_RANGE` | `[0x00]` | strap's stored oldest/newest record range |
| 35 | `GET_HELLO_HARVARD` | `[0x00]` | identity/version hello |
| 39 / 40 | `SET_LED_DRIVE` / `GET_LED_DRIVE` | — | optical LED drive (research) |
| 41 / 42 | `SET_TIA_GAIN` / `GET_TIA_GAIN` | — | optical front-end gain (research) |
| 43 / 44 | `SET_BIAS_OFFSET` / `GET_BIAS_OFFSET` | — | optical bias (research) |
| 63 | `SEND_R10_R11_REALTIME` | `[0x00]` off / `[0x01]` on | the **real** type-43 raw-stream switch |
| 66 | `SET_ALARM_TIME` | `[0x01]+epoch u32 LE+[0,0]` | arm firmware alarm |
| 67 | `GET_ALARM_TIME` | `[0x01]` | read armed alarm |
| 68 | `RUN_ALARM` | `[0x01]` | app-driven alarm now |
| 69 | `DISABLE_ALARM` | `[0x01]` | disarm firmware alarm |
| 76 | `GET_ADVERTISING_NAME_HARVARD` | `[0x00]` | advertised name |
| 79 | `RUN_HAPTICS_PATTERN` | `[patternId, loops, 0,0,0]` | buzz a preset haptic pattern |
| 80 | `GET_ALL_HAPTICS_PATTERN` | — | enumerate preset patterns |
| 81 / 82 | `START_RAW_DATA` / `STOP_RAW_DATA` | `[0x01]` | raw-data collection toggle |
| 84 | `GET_BODY_LOCATION_AND_STATUS` | — | wrist/body-location status |
| 96 / 97 | `ENTER_HIGH_FREQ_SYNC` / `EXIT_HIGH_FREQ_SYNC` | `[0x00]` | high-freq offload mode |
| 98 | `GET_EXTENDED_BATTERY_INFO` | — | extended battery (mV etc.) |
| 100 | `CALIBRATE_CAPSENSE` | — | recalibrate cap-touch |
| 105 / 106 | `TOGGLE_IMU_MODE_HISTORICAL` / `TOGGLE_IMU_MODE` | `[0x01]` | IMU stream mode |
| 107 | `ENABLE_OPTICAL_DATA` | — | optical (PPG) data |
| 122 | `STOP_HAPTICS` | `[0x00]` | stop an in-progress haptic |
| 123 | `SELECT_WRIST` | — | set strap wrist |

**Payload builders** in `WhoopCommand`:

- `setAlarmPayload(epochSec:)` → `[0x01] + epoch u32 LE + [0x00, 0x00]` (7 bytes).
- `BLEManager.setClockPayload(now:)` → `[secs u32 LE][0,0,0,0]` (8 bytes; subseconds in
  1/32768 s, zero is fine).

> **Note on `ENTER_HIGH_FREQ_SYNC` (96):** current builds do **not** enter high-freq sync; they
> send `EXIT_HIGH_FREQ_SYNC` (97) defensively on connect to release a strap a previous app may
> have parked there. Plain `SEND_HISTORICAL_DATA` returns the type-47 store without it.

### Additional 5-class command numbers

Command bytes present on a 5-class (MAVERICK) strap beyond the safe subset above. NOOP does not
send these; they are recorded for completeness.

| Code | Command | Purpose |
|-----:|---------|---------|
| 48 (0x30) | `SEND_EVENT_PACKETS` | flush stored event packets |
| 61 (0x3D) | `SET_AFE_PARAMETERS` | set optical AFE parameters |
| 62 (0x3E) | `GET_AFE_PARAMETERS` | read optical AFE parameters |

On MAVERICK the clock commands also answer in the high opcode space — `SET_CLOCK` at 146 (0x92)
and `GET_CLOCK` at 147 (0x93), alongside `GET_HELLO` at 145 (0x91) — distinct from the 4.0
numbers (10 / 11) above.

The strap further exposes an ECG/HeartKey command family (`ECG_MAIN_CONTROL`, `ECG_SEND_RAW`,
`ECG_SAVE_RAW`, `ECG_SAVE_FILTERED`, `ECG_SELECT_WRIST`; five consecutive codes around 0x7B–0x8B),
an `IMU_SET_DATA_STREAM` (code 106, shared with `TOGGLE_IMU_MODE`), and a `UART_DISABLE` (0x61–0x69).
Exact codes for these are unconfirmed.

### Destructive commands — *do not send*

These exist on the wire but are **deliberately excluded** from `WhoopCommand`. They can wipe
data, brick, or power-cycle the strap. NOOP must never send them.

| Code | Command | Hazard |
|-----:|---------|--------|
| 25 | `FORCE_TRIM` | discards stored data |
| 32 | `POWER_CYCLE_STRAP` | power-cycles (gated probe exception — see below) |
| 36 | `START_FIRMWARE_LOAD` | firmware write |
| 37 | `LOAD_FIRMWARE_DATA` | firmware write |
| 38 | `PROCESS_FIRMWARE_IMAGE` | firmware write |
| 45 | `ENTER_BLE_DFU` | enters DFU bootloader |
| 99 | `RESET_FUEL_GAUGE` | resets battery fuel gauge |

**Two guarded exceptions — both restarts, both non-destructive** (a restart keeps the strap's stored
data and just re-advertises after boot). Neither is ever sent automatically or on any connect/offload path.

- **`REBOOT_STRAP` (29)** — the normal Restart. NOOP already triggers a reboot today via
  `SET_ADVERTISING_NAME_HARVARD` (rename applies on reboot). In `WhoopCommand` as `rebootStrap`, sent only
  from the user-initiated, confirmation-gated "Restart strap" action (`BLEManager.rebootStrap()` /
  `WhoopBleClient.rebootStrap()`) (#166).
- **`POWER_CYCLE_STRAP` (32)** — a harder restart, in the enum as `powerCycleStrap` **only** as a candidate
  for the WHOOP 4.0 reboot probe (below). Sent only from `rebootProbe(.powerCycle32Empty)`, itself gated
  behind Test Centre → Connection + a confirmation, and 4.0-only. Never on a default install.

Everything else in this table stays out of the enum entirely.

**WHOOP 4.0 reboot probe (#235).** A real 4.0 silently ignores the production `REBOOT_STRAP` frame (see
below) and the correct 4.0 reboot frame is unknown. The probe (Test Centre → Connection, 4.0 only) sends
one non-destructive candidate at a time — `REBOOT_STRAP(29)` empty, `POWER_CYCLE_STRAP(32)` empty, or
`REBOOT_STRAP(29)` with `[0x01]` — reusing the reboot watchdog so the strap log shows which one drops the
link (worked) vs is ignored. The definitive fix is still an HCI capture of the official app rebooting a
4.0 (the way the alarm frame was pinned, #535). Driven by `BLEManager.rebootProbe(_:)` /
`WhoopBleClient.rebootProbe(...)`; candidates enumerated in `RebootProbeVariant`.

**Payload forms** (decoded from the official app's command builders — recorded so the wire format is
*known*: for the destructive commands, known-and-avoidable; for the one guarded exception,
`REBOOT_STRAP`, known-and-used by `rebootStrap()`). The opcodes are shared across WHOOP 4 (harvard)
and WHOOP 5/MG (puffin): the app's unified command enum (`EnumC58479e`) uses the same `25`/`29`/`32`
on both transports — unlike haptics, which has a maverick-specific `0x13`.

- `FORCE_TRIM` (25) — body is **two little-endian int32 range args**. The app's "erase everything"
  form sets both to `-16843010` (`0xFEFEFEFE`), an 8-byte sentinel that trims the entire stored
  range (builder `rh0.C45484g`: `new C45484g(-16843010, -16843010)`). It is **not** an empty/`[0x00]`
  payload. This wipes the rolling ~14-day flash history — anything not already offloaded is gone.
- `REBOOT_STRAP` (29) — **empty body** (builder `rh0.C45476d0` passes a null payload). The strap drops
  the BLE link and re-advertises after boot; stored data is kept. Non-destructive, but interrupts any
  in-flight offload. **WHOOP 5.0 (puffin): hardware-confirmed** — the empty-body frame reboots a 5.0
  (fw 50.40.1.0, #227). **WHOOP 4.0 (harvard): NOT confirmed** — a real 4.0 silently ignores this
  empty-body frame (#235: no reboot, no disconnect, no COMMAND_RESPONSE), so the correct 4.0 form (a
  payload byte? a different opcode?) still needs an HCI capture of the official app rebooting a 4.0.

---

## 7. Historical-data offload (backfill)

The type-47 store is the strap's rolling ~14-day biometric history and is NOOP's **primary**
metric source (it is re-offloaded every 15 minutes while connected, mirroring WHOOP). An offload
is bracketed by `METADATA` (type 49) control frames and acknowledged chunk-by-chunk so the strap
can safely trim what it has handed over.

### 7.1 MetadataType (`METADATA[6]`)

`enums.MetadataType` in `whoop_protocol.json`; classified by `classifyHistoricalMeta(_:)`
(`HistoricalMeta.swift`).

| Value | Name | Meaning |
|------:|------|---------|
| 1 | `HISTORY_START` | offload beginning; start accumulating a chunk |
| 2 | `HISTORY_END` | chunk boundary; carries the trim cursor — **ack to advance** |
| 3 | `HISTORY_COMPLETE` | offload finished; close the session |

### 7.2 `HISTORY_END` payload layout

The `metadata` post-hook decodes the payload (which begins at `frame[7]`, after `[type][seq]
[cmd]`) as `struct '<LHLL'`:

| Frame offset | Payload offset | Field | Type | Meaning |
|-------------:|---------------:|-------|------|---------|
| 7 | 0 | `unix` | `u32` LE | record time (seconds) |
| 11 | 4 | `subsec` | `u16` LE | sub-seconds |
| 13 | 6 | `unk0` | `u32` LE | (unmapped) |
| 17 | 10 | `trim_cursor` | `u32` LE | ack with this to advance the strap's trim |

The 8-byte `end_data` the ack requires is `frame[17..25]` (= payload `[10..18]`), recovered by
`Backfiller.endData(from:)`. The trim cursor is the first `u32` of that slice.

### 7.3 Session state machine

```
SEND_HISTORICAL_DATA([0x00], .withResponse)
        │
        ▼
HISTORY_START ─▶ open chunk, accumulate type-47 records
   │
   ├─ HISTORICAL_DATA … HISTORICAL_DATA …            (records buffered)
   │
   ├─ HISTORY_END(unix, trim)  ──▶ finishChunk:
   │       1. decode chunk  (extractHistoricalStreams, using ClockRef)
   │       2. await store.insert(decoded)            ── decoded durable
   │       3. [if raw enabled] await enqueueRawBatch ── raw durable
   │       4. await setCursor("strap_trim", trim)    ── cursor durable
   │       5. ackTrim → HISTORICAL_DATA_RESULT([0x01]+end_data, .withResponse)
   │       (chunk cleared; chunkOpen stays TRUE — high-freq sends repeated ENDs)
   │
   └─ HISTORY_COMPLETE ─▶ isBackfilling = false, close session
```

High-frequency offload sends **one** `HISTORY_START` then **repeated** `HISTORY_END`s (a chunk
close roughly every ~50 records), so `Backfiller.begin()` starts with `chunkOpen = true`, and
`finishChunk(...)` snapshots-and-clears the accumulated frames but leaves the chunk open so the
following records form the next chunk. An `END` with no accumulated records is **still acked**
(that is how the offload progresses).

### 7.4 Safe-trim invariant

A chunk is forgotten by the strap only after it is locally durable end-to-end. From
`Backfiller.finishChunk(...)`:

```
decode → await insert(decoded) → [await enqueueRawBatch] → await setCursor("strap_trim") → ackTrim
```

Any thrown error short-circuits before the ack, so an un-persisted chunk is never trimmed. The
ack itself is the link-layer half: `HISTORICAL_DATA_RESULT(23)` with payload `[0x01] + end_data`
written `.withResponse`, so the strap discards the chunk only once the write is confirmed. The
`strap_trim` cursor is persisted, so the next session resumes where the last left off — never
waiting on a network.

### 7.5 Watchdog & liveness

- **Idle watchdog** (`backfillIdleTimeoutSeconds = 60`): re-armed on every genuine offload frame
  (47/48/49/50) and only those; if the strap goes silent the session exits and resumes next time
  via the durable cursor. The live type-43 flood is dropped during offload so it cannot starve
  chunk acks.
- **Stuck detector** (`StuckStrapDetector`): after an offload, if the strap reports records newer
  than NOOP's frontier (from `GET_DATA_RANGE`, parsed by `dataRangeNewestUnix(from:)`) **and**
  that frontier has been frozen for the detector window, it flags `strapNeedsReboot` and attempts
  a defensive recovery (`EXIT_HIGH_FREQ_SYNC` + `SET_CLOCK`). Off-wrist / caught-up (strap not
  ahead) is **not** treated as stuck.

---

## 8. Decoded output (`ParsedFrame`)

`parseFrame(_:)` returns a `ParsedFrame` with the validated envelope, a typed field list
(`[DecodedField]`), and a flat `parsed: [String: ParsedValue]` dictionary that downstream code
reads. Key entries by packet type:

| Packet | `parsed` keys (examples) |
|--------|--------------------------|
| `REALTIME_DATA` (40) | `heart_rate`, `rr_intervals` |
| `REALTIME_RAW_DATA` (43) | `heart_rate`, `rr_intervals`, IMU axis means, `ppg_mean` |
| `EVENT` (48) | `event`, `battery_pct`, `battery_mV`, `battery_charging` |
| `COMMAND_RESPONSE` (36) | `battery_pct`, `clock`, `fw_harvard`, `fw_boylston`, `history_oldest`, `history_newest` |
| `HISTORICAL_DATA` (47) | `hist_version`, schema-versioned biometric fields, `rr_intervals` |
| `METADATA` (49) | `meta_type`, `unix`, `subsec`, `trim_cursor` |
| `CONSOLE_LOGS` (50) | `log` (capped at 2048 chars) |

`HISTORICAL_DATA` (type-47) layout is selected by the version byte (`seq`) via
`Schema.resolveVersion(_:_:)`, which follows a `ref` chain (e.g. V12 → V24) so newer versions
inherit a base layout and override only what changed. The streamed decode that feeds SQLite is in
`Streams.swift` / `HistoricalStreams.swift` (`extractStreams`, `extractHistoricalStreams`).

---

## 9. File map

| Path | Responsibility |
|------|----------------|
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift` | SOF/length/CRC8/CRC16/CRC32, `verifyFrame`, `Reassembler`, `frameFromPayload` |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift` | `parseFrame` (4.0 + 5.0), `ParsedFrame`, field builder |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceFamily.swift` | UUID strings, header-CRC kind, `CLIENT_HELLO`, puffin aliasing |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Schema.swift` | JSON schema model + `loadSchema()` |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift` | per-type irregular-field decoders |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift` | `classifyHistoricalMeta` (START/END/COMPLETE) |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json` | canonical enums + packet layouts |
| `Strand/BLE/BLEManager.swift` | CoreBluetooth transport, bond, connect lifecycle, backfill orchestration |
| `Strand/BLE/Commands.swift` | safe `WhoopCommand` set + outbound frame builder |
| `Strand/BLE/FrameRouter.swift` | decode → `LiveState` (UI) |
| `Strand/BLE/StandardHeartRate.swift` | `0x2A37` HR/R-R parser |
| `Strand/Collect/Backfiller.swift` | historical-offload state machine + safe-trim invariant |

---

*Reverse-engineering credit: `johnmiddleton12/my-whoop` (WHOOP 4.0) and `b-nnett/goose`
(WHOOP 5.0). This is an independent interoperability project for the user's own device and data;
it is not affiliated with WHOOP and is not a medical device.*
