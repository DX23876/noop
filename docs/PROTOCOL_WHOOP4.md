# WHOOP 4 profile

Read the [scope and compatibility](PROTOCOL.md#scope-and-compatibility) before applying this page.

## Version and validation boundary

This profile combines version-labelled device observations with supported
interoperability behavior. The principal version boundary is MAXIM 41.17.6.0 plus NORDIC
17.2.2.0. A supported command is not automatically a complete request/response
contract or a validated physical effect. A command or field documented only for
WHOOP 5/MG is not inherited.

This profile aims for the same **topic coverage** as the WHOOP 5/MG handbook:
transport, commands, records, configuration, updates, validation and open gaps all
have an explicit home. That is documentation parity, not a claim of equal wire or
runtime depth. WHOOP 4 sections remain shallower wherever only supported behavior or a
small set of device observations exists, and every such boundary stays
visible instead of being filled from WHOOP 5/MG.

Known record diversity is material: the documented layouts include legacy type-47
layouts v5/7/9/12 and v24. Version 41.17.6.0 produces v24 by default and can also
produce the distinct 84-byte v25 layout, depending on device configuration. Neither layout is
universal. Select by the emitted record version and validated length,
never by the marketing generation alone.

| Topic | WHOOP 4 authority |
|---|---|
| GATT, envelope, response offsets | This page and [transport](PROTOCOL_TRANSPORT.md#whoop-4) |
| Commands | [Comparative matrix](PROTOCOL_COMMANDS.md#canonical-command-matrix) and [WHOOP 4 contracts](PROTOCOL_COMMANDS.md#whoop-4) |
| History and battery | [WHOOP 4 transport profile](PROTOCOL_TRANSPORT.md#whoop-4) |
| Measurements | [WHOOP 4 sensor records](PROTOCOL_SENSORS.md#whoop-4) |
| Configuration and updates | Explicit generation boundaries in [configuration](PROTOCOL_CONFIGURATION.md#whoop-4) and [updates](PROTOCOL_UPDATES.md#whoop-4) |
| Alarms and haptics | [Alarms](PROTOCOL_ALARMS.md#whoop-4) |
| Shared concepts | [Shared concepts](PROTOCOL_CONCEPTS.md) |

## Hardware overview

The following components are documented for the 41.17.6.0 / 17.2.2.0 package.
Part identities explain which protocol contracts exist; they do not imply
calibration or physical validation.

| Function | Component | Protocol relationship |
|---|---|---|
| Bluetooth LE processor | <a id="whoop4-nrf52840"></a>Nordic nRF52840 (application plus SoftDevice/bootloader, updated as a DFU package) | Exposes the `61080001-…` service and the standard Heart Rate and Battery services; the update container carries a separate NORDIC image. |

WHOOP 4 splits Bluetooth work and application work across separate processors.
The path between them is not visible at the BLE interface and remains outside
this reference, as described in
[transport](PROTOCOL_TRANSPORT.md#whoop-4-transport-profile).

<a id="whoop-40--service-61080001-"></a>

## WHOOP 4 — service `61080001-…`

The UUIDs below are the values the strap exposes.

| Role | UUID | Direction |
|------|------|-----------|
| Custom service | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` | — |
| Command write | `61080002-8d6d-82b8-614a-1c8cb0f8dcc6` | app → strap |
| Command-response notify | `61080003-8d6d-82b8-614a-1c8cb0f8dcc6` | strap → app |
| Event notify | `61080004-8d6d-82b8-614a-1c8cb0f8dcc6` | strap → app |
| Data notify (fragmented) | `61080005-8d6d-82b8-614a-1c8cb0f8dcc6` | strap → app |

<a id="21-whoop-40-envelope"></a>
<a id="whoop-40-envelope"></a>

## WHOOP 4 envelope

```
┌──────┬───────────────┬───────┬───────────── inner ─────────────┬─────────────┐
│ 0xAA │ length  u16 LE │ crc8  │ type │ seq │ cmd │  payload …    │ crc32 u32 LE│
│ [0]  │ [1..3)         │ [3]   │ [4]  │ [5] │ [6] │ [7 .. len)    │ [len .. +4) │
└──────┴───────────────┴───────┴───────────────────────────────────┴────────────┘
total frame size = length + 4
```

- **`0xAA`** — Start Of Frame.
- **`length`** — `u16` little-endian. Equals `inner.count + 4` (the inner `[type][seq][cmd]
  payload]` plus the 4 envelope bytes). It is the offset at which the CRC32 trailer begins.
- **`crc8`** — CRC8 (table-driven, poly `0x07`) computed over the **two length bytes only**
  (`frame[1]` and `frame[2]`).
- **inner record** — `type` (packet type), `seq` (sequence / version byte), `cmd`
  (command number), then the payload.
- **`crc32`** — standard zlib CRC-32 (reflected, poly `0xEDB88320`), `u32` little-endian,
  computed over the **inner bytes** `frame[4 .. length)`.

Accept a received WHOOP 4 frame only when all of the following hold:

- the declared length is at least 7;
- the declared length plus 4 is at most the received frame size;
- CRC8 over bytes 1–2 equals byte 3;
- CRC32 over bytes `4 .. length` equals the little-endian trailer word at offset `length`.

<a id="5-bond-handshake--connect-lifecycle-whoop-40"></a>
<a id="bond-handshake--connect-lifecycle-whoop-40"></a>

## Bond handshake & connect lifecycle (WHOOP 4)

A working connection sequence for WHOOP 4 is below. A write acknowledgement is not
independent proof of a persistent OS bond. In the observed sequence, command traffic
becomes usable after one confirmed write is acknowledged without error.

```
scan(service 61080001) ─▶ connect ─▶ discover services
                                       └▶ discover characteristics
                                            ├ confirmed GET_BATTERY_LEVEL write on 0002
                                            └ notification subscriptions on 0003/0004/0005/2A37/2A19
        confirmed-write acknowledgement without error ─▶ link usable for commands
```

The ordered command sequence that follows is:

1. `GET_HELLO_HARVARD` (35) — version/identity hello.
2. `GET_ADVERTISING_NAME_HARVARD` (76).
3. `REPORT_VERSION_INFO` (7) — reads the documented Harvard and Boylston version
   components from its 68-byte response body.
4. `SET_CLOCK` (10) — the eight- and nine-byte request forms are outside the
   documented 41.17.6.0 command set. On some devices one of the two forms was
   observed to latch; read back to confirm.
5. `GET_CLOCK` (11) — the empty and `00` request forms are outside the documented
   41.17.6.0 command set. Use the form accepted by the device for readback.
6. `SEND_R10_R11_REALTIME` (63) with `[0x00]` — stops the roughly 2/s type-43 raw
   flood. This is the control for that stream; `STOP_RAW_DATA` (82) does not
   affect it.
7. `GET_DATA_RANGE` (34) — reads the strap's stored record range.
8. The first historical offload, after the link has settled.

**Observed in device captures:** re-running this sequence in the middle of an
offload stopped type-47 streaming. Run it once per connection. Scheduling around
the sequence is application policy, not required protocol timing; the NOOP policy
is recorded on the [implementation page](PROTOCOL_IMPLEMENTATION.md#noop-connection-policy).

> WHOOP 5/MG instead writes the fixed `CLIENT_HELLO` [frame](PROTOCOL_WHOOP5.md#connection-and-frame-format) to its `…0002` command
> characteristic immediately after discovery.

[Next: WHOOP 4 commands](PROTOCOL_COMMANDS.md#whoop-4)

---

<a id="72-history_end-payload-layout"></a>

## `HISTORY_END` payload layout

The following offset table is the documented layout for this WHOOP 4 version.
WHOOP 5/MG has a separate [history contract](PROTOCOL_TRANSPORT.md#historical-synchronization-boundaries-retries-and-range-interpretation);
do not reuse these offsets for it.

The acknowledgement payload begins at frame offset 7 and is laid out as follows:

| Frame offset | Payload offset | Field | Type | Meaning |
|-------------:|---------------:|-------|------|---------|
| 7 | 0 | `unix` | `u32` LE | record time (seconds) |
| 11 | 4 | `subsec` | `u16` LE | sub-seconds |
| 13 | 6 | `reserved` | `u32` LE | unmapped |
| 17 | 10 | `trim_cursor` | `u32` LE | ack with this to advance the strap's trim |

The eight-byte acknowledgement block is `frame[17..25]` (= payload `[10..18]`).
The trim cursor is the first `u32` of that slice.

<a id="get_hello_harvard-35-response--the-whoop-40-serial"></a>

## `GET_HELLO_HARVARD` (35) response — the WHOOP 4 serial

A WHOOP 4 exposes no DIS Serial Number String (`0x2A25`), so this response is the only place its stable
serial appears. In the captures on record the response payload (sliced past `SOF+len+crc8` and
`[type,seq,cmd,origin_seq,result]`, i.e. from byte 9 of the frame) is **131 bytes** and carries two
alphanumeric runs:

| payload offset | length | what |
|---|---|---|
| 14 | 10 | **strap serial field** — nine serial bytes plus a terminating NUL |
| 24 | 54 | **key and signature material** — sensitive; never log it or let it become an id |

The serial content occupies nine bytes in the fixed ten-byte field at payload
offset 14; the tenth byte is NUL. Treating an arbitrary alphanumeric run as
identity could instead expose the adjacent sensitive region.

**Documented for this version; observed in device captures.** If another version
does not expose a plausible nine-byte serial at this offset, leave identity
unresolved rather than scanning into the sensitive region.

## Commands and records

The [canonical matrix](PROTOCOL_COMMANDS.md#canonical-command-matrix) contains
every ID 1–159 exactly once and distinguishes supported, observed, partial,
unsupported and unknown states per generation. Its
[WHOOP 4 contracts](PROTOCOL_COMMANDS.md#whoop-4) retain exact
observed requests and compatibility knowledge. The 41.17.6.0 classification covers
IDs 1–132: 85 matrix entries are `S` and 47 are `U`. The remaining
27 IDs in the complete matrix are outside that version-specific range.

Version differences remain explicit. In particular, clock and history forms
outside the documented 41.17.6.0 command set remain separately labelled even
when device captures show working behavior. Commands 20, 22 and 23 were observed
working on that version, including type-47 delivery and `HISTORY_END`
acknowledgement. On some devices one of the two SET_CLOCK forms was observed to
latch; read back to confirm.

The complete matrix is broader than any application's transmission subset. WHOOP 4 battery replies
use the legacy `u16le / 10` percent convention. Historical record versions have
distinct layouts; the v24 optical/respiration fields must not be mapped onto
WHOOP 5 records by adding four to offsets. See the
[historical measurement discussion](WHOOP5_DEEP_DATA.md#spo₂-and-respiration-interpretation-limits).

<a id="legacy-imu-client-schema-layout"></a>

## Legacy IMU layout

The documented layout for this version has payload length 1,917, corresponding to
declared length 1,924. It contains 100 signed `i16le` values per axis. Absolute
frame offsets are 89/289/489 for acceleration X/Y/Z and 692/892/1092 for gyro
X/Y/Z. Acceleration scale `1/4096` and gyro scale `2000/32768` are commonly
applied interpretations, not confirmed device parameters or WHOOP 5/MG scaling.
