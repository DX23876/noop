# WHOOP configuration and collection controls

Applicability: [central scope and compatibility](PROTOCOL.md#scope-and-compatibility).

This is the configuration companion to [the protocol reference](PROTOCOL.md).

## Contents

- [WHOOP 4](#whoop-4)
  - [WHOOP 4 state model](#whoop-4-state-model)
  - [WHOOP 4 legacy controls](#whoop-4-legacy-controls)
  - [WHOOP 4 feature-name enumeration](#whoop-4-feature-name-enumeration)
  - [WHOOP 4 configuration gaps](#whoop-4-configuration-gaps)
- [WHOOP 5/MG](#whoop-5mg)
  - [Named configuration interface](#named-configuration-interface)
    - [Value types and storage](#value-types-and-storage)
  - [Device key inventory](#device-key-inventory)
  - [Feature flag inventory](#feature-flag-inventory)
  - [Collection, storage and live transport](#collection-storage-and-live-transport)
  - [Other sensor configuration](#other-sensor-configuration)
    - [AFE parameters (61/62)](#afe-parameters-6162)
    - [Signal-processing configuration (138)](#signal-processing-configuration-138)
    - [Gyro mode (150/152)](#gyro-mode-150152)
  - [Configuration reads — commands 121 and 128](#configuration-reads--commands-121-and-128)
  - [Collection settings and overlapping controls](#collection-settings-and-overlapping-controls)
  - [Analog configuration readback](#analog-configuration-readback)
  - [Collection and live-stream coordination](#collection-and-live-stream-coordination)
  - [R22 version preferences](#r22-version-preferences)

<a id="whoop-4-boundary"></a>

## WHOOP 4

WHOOP 4 does not inherit the 50.42.1.0 named-key descriptors, 65-byte SET/GET
records, AFE selector semantics, R20/R21 persistent policies or gyro-mode contract.
WHOOP 4 has separate contracts, plus a complete
41.17.6.0 support classification for IDs 1–132. AFE, raw/record routing, device
configuration and feature-flag operations are present, but this does not import
WHOOP 5/MG record shapes or make every WHOOP 4 wire contract complete.

In particular, WHOOP 4 command 105 is outside the documented 41.17.6.0 command
set and has no recorded observation. Command 106 sets IMU stream
state with `[01, state]`, and command 107 reads it with `[01]`; command 63
independently controls R10/R11 realtime output. WHOOP 4 raw
collection, live transport, historical saving and persistent policy must remain
separate states just as on WHOOP 5/MG, but their bytes must come from the
[WHOOP 4 command profile](PROTOCOL_COMMANDS.md#whoop-4), not from
the revision-1 50.42.1.0 bodies. A feature-name enumeration reports names, not
values, defaults, support for writes, or successful physical application.

### WHOOP 4 state model

For each control keep these states separate:

1. request bytes constructed by a client;
2. write accepted by the Bluetooth stack;
3. correlated command result returned by the strap;
4. value read back, where a read operation exists;
5. output/saving behavior observed in packets; and
6. persistence after reconnect or reboot.

Confirmation of an earlier state does not establish later states.

### WHOOP 4 legacy controls

| Area | Operation | WHOOP 4 status | Known boundary |
|---|---|---|---|
| Live HR | command 3, request form `01`/`00` observed in use | **Implemented outside the documented 41.17.6.0 command set** | NOOP sends the proprietary command, but no type-40 transition has been observed for this version; standard HRS remains separate |
| R10/R11 realtime | command 63, body `01`/`00` | **Device capture + supported behavior** | controls observed type-43 output; command 82 did not stop that output |
| Raw collection | commands 81/82, body `01` | **Older request convention** | collection intent is distinct from live transport; persistence and exact storage effect unresolved |
| IMU modes | commands 105–107 | **105 outside the documented set; 106/107 supported SET/GET operations on 41.17.6.0** | 106 uses `[01, state]`; 107 uses `[01]` and returns stored state; the WHOOP 5/MG identifier `ENABLE_OPTICAL_DATA` does not describe this WHOOP 4 operation |
| Analog front end | commands 39–44 and 61/62 | **Supported on 41.17.6.0** | channel plus value/parameter operands are documented; widths, units, ranges and safe values remain incomplete |
| Body placement | command 123 | **Outside the documented 41.17.6.0 command set** | no observation is recorded for this version; wrist selection under this ID belongs to WHOOP 5/MG ECG |

Further supported operations cover record send/save/persistence (46–65, 70–72,
129–132), raw start/stop (81/82), device-config enumeration/set/get
(115/116/119/121), and feature-flag enumeration/set/get (117/118/120/128).
Known fields include channel/parameter/value, revision checks, cursor indices and
success/failure states. Exact request lengths, complete namespaces, authorization
and persistence remain unresolved.

### WHOOP 4 feature-name enumeration

Commands 117 and 118 form a bounded, read-only enumeration sequence.
Command 117 starts/resets a feature enumeration and 118 advances a shared
cursor. A WHOOP 4 R19-era observation
returned feature names, while at least one response value field was contaminated
by a stale shared buffer. Consequently:

- treat returned names as bounded strings and preserve the raw response;
- serialize requests because the cursor is shared state;
- stop by an explicit terminal condition or client limits, not by one malformed name;
- do not interpret an adjacent byte as the feature's current value without an
  independently mapped response layout;
- do not infer write support, default, polarity, persistence or sensor effect.

The observed name inventory belongs to its captured firmware and is not a complete
41.17.6.0 descriptor table. The WHOOP 5/MG 65-byte named-key SET/GET records below
must not be used against WHOOP 4 based on a matching name alone.

### WHOOP 4 configuration gaps

Still open are the supported revision table, complete
feature/device-key inventories, value encodings, storage schema, factory defaults,
write authorization, validation ranges, the order in which a stored value is
applied, and reboot survival. A safe implementation exposes only capture-backed reads and already
proven operational controls; it preserves unknown results rather than probing by
write.

<a id="whoop-5mg-version-baseline"></a>

## WHOOP 5/MG

Unless explicitly labeled historical, the contracts below apply to the **WHOOP
5/MG 50.42.1.0 version baseline**. A stored value, its interpreted policy,
accepted request, effective sensor activity and delivered packet stream are
different states. Do not collapse them into one “enabled” boolean. Device-specific
factory values, power-interruption survival and all hardware variants are not
established by these contracts.

### Named configuration interface

| Operation | Command | Request / response boundary |
|---|---|---|
| Count device keys | 115 | Revision 1; resets the enumeration cursor and returns a one-byte count after revision 1 (two body bytes). |
| Next device key | 116 | Revision 1; advances a shared enumeration cursor, not a caller-supplied index. |
| Count feature keys | 117 | Revision 1; resets the feature enumeration cursor and returns a one-byte count after revision 1 (two body bytes). |
| Next feature key | 118 | Revision 1; advances the feature enumeration cursor. |
| Set device value | 119 | Revision 1, 32-byte key field, 32-byte value field. |
| Set feature value | 120 | Same layout, feature namespace. |
| Read device value | 121 | Revision 1 followed by a 32-byte key field; 65-byte reply. |
| Read feature value | 128 | Same request and reply sizes, feature namespace. |

The current named SET body is **65 bytes** before outer framing/padding. Fields are NUL-terminated; names have at most 31 meaningful bytes in the 32-byte field. Use ASCII values matching the descriptor type below and zero-fill unused field bytes. A shorter historical request, with one value character and a few padding bytes, does not establish the complete request contract. Handling of truncated SET bodies is unresolved; do not use them as capability tests.

Enumeration replies expose revision, index, validity and a bounded name; they do not return values. A false validity byte alone is not a universal terminator. Index 255 is the observed terminal value; the baseline count is one byte and older formats remain separately scoped. Firmware capacity and behavior after repeated empty entries are unresolved. Enumeration requests are sequential because the cursor is shared state.

GET reads configuration storage rather than merely echoing the preceding SET. The current reply is the 65-byte key/value record specified below, including its failure bodies. Validate response command, origin, result, bounds and returned key before using a value. Preserve the bounded value bytes instead of taking the final padded byte as a boolean. A response timeout does not mean that a named key or command does not exist.

#### Value types and storage

| Type | Accepted representation / conversion | Meaning boundary |
|---|---|---|
| Tri-state | Exact NUL-terminated ASCII `0`, `1` or `2` | Numeric policy values, not one universal on/off encoding. |
| Unsigned byte | Decimal integer bounded above by 255 | The accepted value range is not a per-key safe operating range. |
| Tenths | Nonnegative decimal value, scaled by 10 with `+0.5` rounding into bounded integer storage; readback decodes a 16-bit quantity | `max_collection_backlog` uses tenths. It expresses capacity percentage in tenths of a percentage point; safe operating thresholds remain unknown. |

Keep request acceptance, readback, visible effect and persistence as separate
states. A named SET can be acknowledged even when its later visible effect or
reboot persistence is not established. A failed read can yield zero-filled data,
so zero readback can be a fallback rather than a confirmed saved value or factory
default. Read back a changed value when the relevant reply contract is supported,
then separately observe the intended device behavior and reboot survival.

### Device key inventory

All eight names below are eligible for named lookup. Eligibility does not establish a complete behavioral contract or support on every device.

| Key | Value type | Known behavior / remaining limits |
|---|---|---|
| `sigproc_wear_detect` | Tri-state | Wear-detection setting; per-value effect, applied default and safe change conditions unresolved. |
| `enable_rfid` | Tri-state | RFID setting; exact effect, polarity and default unresolved. |
| `max_collection_backlog` | Tenths | Capacity percentage in tenths; strict threshold exceed attempts to clear continuous mode. Safe operating thresholds remain unresolved. |
| `cont_collection_mode` | Unsigned byte | Contributes to optical/IMU collection policy alongside session and persistent requests. Mode 0 removes continuous collection; 1 requests optical and IMU collection. Other accepted bytes are not established supported modes. |
| `whoop_live_hr_in_adv_ind_pkt` | Tri-state | Stored 1 selects this advertising preference before the two-HRM preference; 0/2 do not. Exact advertised contents and timing remain unresolved. |
| `whoop_live_2_hrm_devices` | Tri-state | Stored 1 selects the named preference; 0/2 do not. Exact connection capacity and factory state remain unresolved. |
| `enable_raw_data_w_ecg` | Tri-state | Values `0` and `1` act as true, `2` as false; unavailable readback also acts as true. Enables companion raw optical/IMU handling after successful ECG startup. It is **not** the ECG master gate. |
| `dorset_detection_period_min` | Unsigned byte | Zero or a failed read selects fallback 5; a nonzero value uses the stored byte. The name does not independently establish time units or a safe range. |

In particular, writing zero is not a universal reset-to-off operation. ECG companion
collection remains enabled when readback is zero or unavailable. See [ECG behavior](PROTOCOL_ECG.md)
for its startup and independent live/save controls.

### Feature flag inventory

All 25 descriptors use the tri-state representation. Twenty are eligible for named lookup; five are not. Ineligible names are included so an application does not mistake a readable name or historical write bundle for a supported named SET. For entries without a decoded consumer below, polarity, applied default, packet effect and hardware variation remain **unknown**, regardless of how suggestive the name is.

| Feature key | Named lookup | Known meaning / limit |
|---|---|---|
| `general_ab_test` | Ineligible | No public operational value mapping established. |
| `enable_r22_packets` | Eligible | Historical packet 47/layout 22 master: `1` permits, `0` and `2` do not. Further readiness conditions are documented separately. |
| `enable_r22_v2_packets` | Eligible | A stored 1 is treated as true; 0 and 2 as false. See [version selection](#r22-version-preferences). |
| `enable_r22_v3_packets` | Eligible | A stored 1 is treated as true; 0 and 2 as false. See [version selection](#r22-version-preferences). |
| `enable_r22_v4_packets` | Eligible | A stored 1 is treated as true; 0 and 2 as false. See [version selection](#r22-version-preferences). |
| `enable_r22_v5_packets` | Eligible | A stored 1 is treated as true; 0 and 2 as false. See [version selection](#r22-version-preferences). |
| `enable_r22_v6_packets` | Eligible | A stored 1 is treated as true; 0 and 2 as false. See [version selection](#r22-version-preferences). |
| `enable_r22_v8_packets` | Eligible | Per-version selector semantics unresolved. |
| `enable_r22_v9_packets` | Eligible | A stored 1 is treated as true; 0 and 2 as false. See [version selection](#r22-version-preferences). |
| `make_hrfm_visible` | Eligible | Consumer semantics unresolved. |
| `disable_pip_r26_packets` | Eligible | Inverse historical packet 47/layout 26 permission: `1` removes it; `0` and `2` permit it. Record availability is additionally required; this is not a global optical stop. |
| `wear_detect_bias` | Eligible | Consumer semantics unresolved. |
| `enable_pdaf_walk_det` | Ineligible | No named SET support established. |
| `enable_maverick_model` | Ineligible | No named SET support established. |
| `hr_ch_switching` | Eligible | Enables one prerequisite of the alternate-source branch reflected in R18 bits 4/5; other input and state conditions also apply. See [source selection](PROTOCOL_SENSORS.md#r18-quality-adjacent-source-selection-bits). |
| `ir_hw_switching` | Eligible | Consumer semantics unresolved. |
| `enable_passive_strap_fit_gen5` | Eligible | Consumer semantics unresolved. |
| `enable_sig11_during_sleep` | Ineligible | Historical bundle inclusion does not establish named SET support here. |
| `dorset_inhibit_wpt` | Eligible | Consumer semantics unresolved. |
| `enable_sig12` | Ineligible | Historical bundle inclusion does not establish named SET support here. |
| `enable_frizzle_burst_mode` | Eligible | Consumer semantics unresolved. |
| `ir_1x_enable` | Eligible | Consumer semantics unresolved. |
| `enable_rocky_again` | Eligible | A change can trigger processing reset/reinitialization during configuration refresh; algorithm and physical effects remain unresolved. |
| `project_drawbridge` | Eligible | Stored 1 enables one side of a conditional gate that can skip normal buffered submission and recall deferred work. Another state condition is required; affected record types remain unresolved. Not a general stream-off or privacy control. |
| `wear_detect_fast_event` | Eligible | Consumer semantics unresolved. |

The historical write of ASCII `2` to the R22 master must not be described as universally enabling R22. In this version it removes that master contribution. Likewise the inverse-named PIP flag must not be presented with the same permission polarity. Consumer truth does not establish emitted variants, and v8 remains outside this mapping; do not guess an all-features bundle. Preserve unknown record variants instead of forcing them through a known decoder.

### Collection, storage and live transport

Requests below are command bodies, excluding the transport envelope. Revision-1 boolean controls take `[1, state]` with `state` 0 or 1; other boolean values are rejected. Live transport and persistent settings are separate from shared session requests; overlapping writers require the ordering rules below.

| Control | Commands | Contract and application effect |
|---|---|---|
| Raw collection start/stop | 81 / 82 | Revision 1 supported; start also accepts a revision-2 request whose body remains unresolved. Start/stop is separate from live transport and saving. |
| IMU session saving | 105 | Revision-1 boolean; changes the current session's collection state. It does not establish persistent policy. |
| IMU live transport | 106 | Revision-1 boolean; controls live IMU delivery independently of saved records. |
| Optical session saving | 107 | Revision-1 boolean; changes the current session's optical saving state. The identifier is historical; on WHOOP 5/MG 50.42.1.0 the operation controls optical session saving, not live optical output (that is 108). |
| Optical live transport | 108 | Revision-1 boolean; independently controls live optical delivery. |
| Persistent optical/R20 policy | 153 | Revision-1 boolean. Wire 0 stores explicit off, wire 1 stores on. Nonvolatile write requested, but ACK does not check programming success. |
| Persistent IMU/R21 policy | 154 | Same persistent policy contract, independent of IMU session saving. |

Commands 149, 153 and 154 affect related persistent options. If the existing
options cannot be read, changing one can make other options return to defaults.
This is separate from the [named configuration namespaces](#named-configuration-interface)
above.

For the two dedicated policies, readback behavior treats 1 as true and 0 or 2 as
false; missing or invalid saved state appears as zero. There is no established BLE
getter for these policies. An acknowledgement does not establish successful
persistence, reboot survival or power-loss atomicity.

Raw, individual-sensor and ECG companion controls take effect in request order;
a later raw stop can clear collection requested earlier by another session control.
Persistent and continuous settings remain separate. An acknowledged off request
does not prove that the sensor is idle. Track live output, saving, collection and
persistence separately; startup, reset and disconnect behavior are not universally
known.

The earlier live-IMU sequence starts raw production before enabling live IMU transport; stopping production and disabling that transport are separate cleanup operations. Its 1,244-byte frame contains 100 six-axis samples. This is a versioned example, not a frame size to hard-code for every record. See [sensor layouts](PROTOCOL_SENSORS.md) and [raw capture operations](RAW_DATA_CAPTURE.md).

### Other sensor configuration

#### AFE parameters (61/62)

The request and response structure for the [MAX86176 front end](PROTOCOL_WHOOP5.md#whoop5-max86176)
is 12 bytes, with **no revision prefix**:

| Offset | Width | Field |
|---|---|---|
| 0 | 4 | Channel word, little-endian |
| 4 | 4 | Setting word, little-endian |
| 8 | 4 | Value bits, little-endian: SET input / GET output |

Preserve the complete 32-bit value. Signed display is not proof of a common
physical unit or range: individual settings may normalize nonzero to 1,
truncate to a byte, or run their own validation/conversion. Both commands are
gated by subsystem state. Check the response result before interpreting its
body as readback; failed responses can retain the input words. Successful
readback describes the cached configuration, not proof that the analog front end
was reconfigured or that the value survives a reboot. A failure result does not
prove that nothing changed, and the value in a response is not independently
re-read from hardware.

For generic per-channel settings, canonical channel values are 1–6; lookup
uses their low byte. Do not rely on ignored upper bits. The numeric selector
inventory is:

| Setting | Established contract |
|---|---|
| 1–5, 7–12 | Per-channel values with field-specific conversion/validation; physical labels, units and safe ranges unresolved |
| 6, 22 | Settings 6 and 22 are not accepted |
| 13 | Per-channel boolean; nonzero normalizes to 1 |
| 14–19 | The same channel boolean, selecting channels 1,2,4,5,6,3 respectively regardless of the channel word |
| 20 | Per-channel byte value; SET narrows to u8 |
| 21, 23 | Separate global booleans; user-facing functions unresolved |
| 24 | Low-byte selector 0 or 1; stored/readback value remains that selector; physical interpretation unresolved |

Setting zero and other unlisted selectors fail. These
contracts support encoding and decoding; they do not supply a safe analog
tuning interface or authorize guessing wavelengths, current, gain or defaults.

#### Signal-processing configuration (138)

Signal-processing configuration takes revision 1 and a value byte. All byte values receive success; 0–8 select defined presets with unresolved meanings, while 9–255 do not select a new preset. Storage and reconfiguration are still attempted, and success does not prove persistence. See [service contracts](PROTOCOL_COMMANDS.md#ordinary-service-commands).

#### Gyro mode (150/152)

Commands 150/152 target the [ICM-45686 IMU](PROTOCOL_WHOOP5.md#whoop5-icm-45686)
and use revision 1; SET takes a following boolean byte.

Command 150 argument 0 selects gyro disabled and argument 1 selects enabled.
Command 152 reports the current mode value; it does not prove current sample output.

**A failed gyro SET can still have changed the mode; read back after a failure.**
A failed SET can report failure while GET already returns the new value. Show
uncertain device state; neither success nor failure is an atomic rollback guarantee,
and a changed GET does not establish live gyroscope output. Enable/disable events
115/116 are emitted only after the setting is fully applied.

The strap can select enabled mode during startup, but that is not a guaranteed
final boot state or a user's saved preference. Persistence across reboot, actual
power/sample behavior and later collection-state changes remain separate.

<a id="configuration-reads--commands-121-and-128"></a>

### Configuration reads — commands 121 and 128

Command 121 reads device configuration; 128 reads feature flags. The request is
revision 1 followed by a 32-byte key. Use at most 31 key bytes plus NUL padding.
Both commands return a **65-byte body**, including failures.

| Offset | Width | Field |
|---:|---:|---|
| 0 | 1 | Revision 1 |
| 1 | 32 | First 31 requested key bytes followed by NUL |
| 33 | 32 | Formatted value, terminated within the field |

On SUCCESS, the value is text: depending on the key's type, it can be `0`, `1`,
`2`, an unsigned decimal integer, or an unsigned decimal with one fractional
digit. No binary value or type tag is present. Key-specific meaning and units
must come from the key's schema.

Unknown keys, value-read errors and formatting failures return
result 0, the normalized key echo and an all-zero value field. An underlying
storage-slot read failure is different: an unreadable stored value is returned as
zeros with result 1. A valid key can therefore return result 1 with a formatted
zero fallback despite such a storage failure. Unsupported request revisions
return result 0 with revision 1 and 64 zero bytes, without a key echo. Accept a
value only after checking result 1 and matching the canonical key. A non-NUL
32-byte key is normalized and therefore will not be echoed exactly.

Enumeration-start commands 115 and 117 use revision 1. Their successful body is
two bytes: revision 1 and a **one-byte entry count**. Invalid revision returns
FAILURE with `01 00`. They reset separate enumeration cursors.

### Collection settings and overlapping controls

`cont_collection_mode=0` removes the continuous collection
request; `1` requests both optical and IMU collection. Other nonzero byte values contribute an optical request without the mode-1 IMU
request and can enter an IMU diagnostic path. They
are not established clean operating modes and should not be exposed as supported
choices merely because storage accepts them.

`max_collection_backlog` expresses a percentage of collection capacity, in tenths
of a percentage point. When a continuous collection check observes a percentage
strictly above the configured threshold, it attempts to store continuous mode
zero. Equality does not trigger that action. A zero threshold can therefore end
continuous collection after backlog becomes nonzero. This does not establish
whether the storage attempt succeeded or when another collection source stops.
Entering or changing to continuous policy can be deferred when backlog is at or
above 0.2%, retaining the previous policy and emitting event 124 with transition
value 4 and reason 3. This is separate from the configurable maximum threshold.

Raw collection, individual optical/IMU session controls and ECG companion raw
collection overlap. They update shared session requests rather than independent
ownership counts. A later raw stop can clear session requests previously set by
ECG companion start or an individual sensor control. Persistent and continuous
requests can still contribute. Serialize overlapping operations, retain the
intended application state, and verify the resulting data flow separately from
command acknowledgments.

Advertising preferences also overlap: the standard heart-rate advertising
preference is considered before the two-HRM-device preference. In these preference
checks, stored 1 selects the named branch; 0 and 2 do not. This does not establish
a guaranteed number of simultaneous client connections.

For the R22 master and selectors v2/v3/v4/v5/v6/v9, the configuration consumer
maps stored 1 to true and 2 to false, with zero selecting false. These values do
not prove any particular packet was emitted. The v8 selector is outside this
verified consumer mapping. The inverse-named PIP flag must retain its separately
documented permission inversion. Do not substitute historical write recipes for
version-specific readback and data-flow checks.

For the described processing consumers, `wear_detect_bias`, `hr_ch_switching`,
`ir_hw_switching`, `enable_frizzle_burst_mode`, `ir_1x_enable`,
`enable_rocky_again` and `wear_detect_fast_event` resolve stored 1 as true and
0/2 or read failure as false. This identifies consumer fallback, not the installed
default or the physiological effect. Changes in `disable_pip_r26_packets` or
`enable_rocky_again` can trigger processing reset/reinitialization during
configuration refresh; an accepted settings write need not leave intermediate
processing state untouched.

A stored zero is a consumer fallback, not a factory reset. No factory value,
reconnect survival or reboot outcome is established by these additions.

### Analog configuration readback

Commands 61 and 62 carry three little-endian u32 words: channel, setting and value.
Successful readback describes cached configuration. It does not confirm that
all physical settings have already been applied.

Settings have distinct numeric behavior:

| Setting | Input and readback behavior |
|---|---|
| 1 | Preserves the full input word. |
| 2 | Stores an input contribution; readback returns that contribution plus setting 3, modulo 2^32. |
| 3 | Preserves its input and also changes setting 2 readback through the sum above. |
| 4, 5 and 7, 8 | Each paired selector's low byte must be 1..4. Validation uses both current selectors. Successful readback preserves the assigned full word. |
| 9, 10 | Inputs 0..5 become 0; 6..11 become 8; 12..23 become 16; all larger u32 values become 32, including values above 64. |
| 11, 12 | Inputs 0..3999 become 0; 4000..11999 become 8000; 12000..19999 become 16000; 20000..48000 become 24000. Larger unsigned inputs fail without replacing the previous field. |

For example, setting 2 input 100 with setting 3 equal to 20 reads back as 120.
Changing setting 3 to 30 changes setting 2 readback to 130. These are numeric
interface rules; physical units and safe tuning values are not established.

A successful reply does not prove that the setting is in effect; read back, and
treat command acceptance, cached readback and complete physical application as
separate states. An application failure is not retried automatically. Preserve
uncertainty after an application failure.

### Collection and live-stream coordination

Requested policy selection prioritizes a true persistent preference, then the
shared raw request, then the individual sensor session request, and finally
continuous collection. Multiple collection requests can coexist, and backlog can
delay a requested policy change; selected policy does not prove completed physical
acquisition.

Raw collection can hold a shared collection request in addition to the individual
optical and motion requests. Turning off an individual request, or stopping ECG
companion collection, therefore does not necessarily stop a running raw session.
Raw stop and raw-session expiry clear the shared raw request and the overlapping
session requests. Persistent collection preferences can still keep collection
requested afterward. Treat the operations as overlapping mutable controls and
reconcile their resulting state.

Live motion output has separate requested and active states. A requested change
is applied later. Failure can leave the previous active output state in place. Rapidly sending an enable followed by a disable
before application can also leave output enabled despite the last requested
value being disabled. Serialize opposite changes and check actual output; an
acknowledgment or requested-state readback alone does not confirm application.

A sensor restart clears the temporary collection and live-stream
requests in this version. That does not establish which reset
operations execute initialization, whether persistent preferences are reasserted,
or what remains active after a radio disconnect. Loss of notifications is not
proof that sensing or historical recording stopped. Explicitly reconcile
collection and ECG state after reconnecting.

`enable_r22_packets` gates historical packet 47/layout 22. The inverse
`disable_pip_r26_packets` flag removes historical packet 47/layout 26 publication permission; it is not a global
optical acquisition stop. The latter path also requires record availability.
Unresolved experimental settings should remain opaque: names alone do not prove
physical effects, deployed defaults, safe values or support for additional wire
formats.

### R22 version preferences

R22 preparation chooses enabled version preferences in this order:
**9, 6, 5, 4, 3, 2, then 1 as fallback**. The master R22 flag gates preparation
and historical publication separately. Multiple preferences select one path;
they do not request separate output for each enabled version.

Selection does not guarantee the emitted version. Version 3 falls back to 2
when both selected 32-bit input words are zero. This is a value test, not proof
that sensor data is absent. Version 5 falls back to 4 unless its
readiness result is exactly 1. When version 9 selects its queued replay path,
empty queues cause a fallback to version 4; selecting it does not guarantee fresh version-9 output. See
[queued channels](PROTOCOL_SENSORS.md#r22-version-9-queued-channels-and-sample-encoding). Version 8 is not established in this
selection path. Decode the [actual inner version](PROTOCOL_SENSORS.md#r22-inner-version)
and preserve unfamiliar bodies rather than choosing a layout from settings.
