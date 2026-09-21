# WHOOP transport and core behavior

Applicability: [central scope and compatibility](PROTOCOL.md#scope-and-compatibility).

This extends [the protocol entry page](PROTOCOL.md) with generation-specific
contracts. Earlier WHOOP 4 and WHOOP 5/MG observations are labeled separately.
A defined command does not establish identical behavior on every hardware variant
or connection state. See the [complete command reference](PROTOCOL_COMMANDS.md)
for individual operations.

## Contents

- [WHOOP 4](#whoop-4)
  - [WHOOP 4 frame and response procedure](#whoop-4-frame-and-response-procedure)
  - [WHOOP 4 history lifecycle](#whoop-4-history-lifecycle)
  - [WHOOP 4 battery sources](#whoop-4-battery-sources)
- [WHOOP 5/MG](#whoop-5mg)
  - [Format 1 framing](#format-1-framing)
  - [Responses and correlation](#responses-and-correlation)
  - [Format 2 boundary](#format-2-boundary)
  - [Clock and identity contracts](#clock-and-identity-contracts)
  - [History sequencing and storage ownership](#history-sequencing-and-storage-ownership)
  - [Scheduled-control timing](#scheduled-control-timing)
  - [Complete response bodies](#complete-response-bodies)
    - [Battery level — command 26](#battery-level--command-26)
    - [Hello — command 145](#hello--command-145)
    - [Battery pack — command 151](#battery-pack--command-151)
    - [Data range — command 34](#data-range--command-34)
  - [Historical synchronization: boundaries, retries and range interpretation](#historical-synchronization-boundaries-retries-and-range-interpretation)
  - [Battery replies and cached accessory information](#battery-replies-and-cached-accessory-information)
  - [Interruption and recovery](#interruption-and-recovery)
  - [Connection and error recovery boundaries](#connection-and-error-recovery-boundaries)

<a id="whoop-4-transport-profile"></a>

## WHOOP 4

The following boundaries combine version-identified WHOOP 4 observations with
supported interoperability behavior. Neither imports the WHOOP 5/MG contract, and a parsed response does
not by itself prove a persistent or physical effect.

| Boundary | WHOOP 4 contract |
|---|---|
| Complete frame | **Observed in device captures:** `aa`, `length:u16le`, CRC8 over the two length bytes, inner record at 4, CRC32 trailer at `length`; complete size `length + 4` |
| Minimum accepted command frame | **Documented for this version:** the inner record needs type, sequence and command; a zero-payload command therefore has declared length 7 and complete size 11 |
| Response prefix | **Observed in device captures:** command at 6, originating request sequence at 7, result at 8, command body at 9 |
| Fragmentation | **Observed in device captures:** notifications on characteristic `…0005` can split frames; reassemble by the WHOOP 4 declared total and validate both CRCs before decoding |
| Clock | Commands 10/11 are outside the documented 41.17.6.0 command set. On some devices one of the two SET_CLOCK forms was observed to latch; read back to confirm |
| History metadata | **Retained layout + capture:** type 49 carries START/END/COMPLETE. `HISTORY_END` data begins at frame 7; its acknowledgement block is frame 17–24 |
| History records | **Observed in device captures:** type 47 layouts vary by emitted version and length. Persist the full accepted frame and rejected-record data before command-23 acknowledgement |
| Battery | **Observed in device captures:** battery percent from command 26 is `u16le / 10`. Command 98 returns the cached 25-byte extended record; event 63 announces extended battery information, while event 98 means high-frequency sync disabled. There is no WHOOP 4 command-151 fuel-gauge contract |
| Identity | **Observed in device captures:** DIS serial is not used by this profile. A command-35 Harvard hello layout contains a ten-byte serial field and adjacent key and signature material; logs must redact the sensitive block |

WHOOP 4 exposes the documented BLE, command, history and sensor interfaces;
communication between the device's processors is outside this reference.

Result values 0/1/2/3 have been observed in the same failure/success/pending/
unsupported roles, but a result byte alone does not import the WHOOP 5/MG response
body or asynchronous lifecycle. Multiple CRC-valid replies to one range request
have been captured; correlate by command, origin sequence, connection and request
lifecycle rather than taking the first matching command number.

### WHOOP 4 frame and response procedure

1. Discard bytes before the first `aa`, then wait for at least
   four bytes before reading the declared length. Apply a bounded maximum before
   allocating or waiting indefinitely.
2. The declared length runs from packet type at byte 4 through
   the final CRC32; complete size is `length + 4`. CRC8 uses polynomial `0x07`
   over the two little-endian length bytes. CRC32 covers the inner bytes beginning
   at byte 4 and excludes its own four-byte trailer.
3. **Observed in device captures:** route packet type 36 as a command response and use
   `(command, origin sequence, connection generation)` as the minimum correlation
   key. The byte at 5 is the response frame's own sequence and is not sufficient.
4. Preserve unknown result values and short bodies as raw
   diagnostics. Do not read through the declared boundary into CRC bytes.
5. **Observed in device captures:** one request may emit pending followed by a final
   response, or more than one CRC-valid response. A local wait limit closes local
   waiting; it does not prove device cancellation.

Sequence reuse after eight-bit wrap, late notifications after reconnect and the
phone-visible duplicate-request policy remain **unknown**.

### WHOOP 4 history lifecycle

**Observed in device captures:** command 22 with body `00` begins the legacy history
offload without requiring the WHOOP 5/MG data-range preflight. Type-49 metadata
marks START, END and COMPLETE; type-47 frames between those markers are records.
For END, retain the eight bytes at frame offsets 17–24 exactly and acknowledge
with command 23 body `01 || acknowledgement_block[8]` only after durable local commit. The
first word is the trim cursor; the second word must be retained as wrap state
rather than regenerated.

The chunk durability boundary covers accepted records, rejected-layout data,
raw-frame retention and the cursor update. If any part fails, withhold the
acknowledgement. COMPLETE ends the session but does not retroactively commit
an open chunk. Command 97 is not a required precondition for command 22.

On 41.17.6.0, command 96 uses a revision/legacy byte followed by `period:u16le`
and `duration:u16le`; period is at least 60 seconds and duration is at most 28,800
seconds. Command 97 evaluates no body fields. Both return result 1 without a body.
Event 97 reports high-frequency sync enabled, and event 98 reports it disabled.

The history protocol includes metadata start/end, data/event phases, read-page
plus wrap count, trim/read cursors, abort-on-disconnect, phase timeouts, result
retries, burst mode and configurable burst size. Commands 20, 22 and 23 are outside
the documented 41.17.6.0 command set but were observed working in device captures
on that version, including type-47 delivery and `HISTORY_END` acknowledgement.

**Open questions:** replay after disconnect, maximum chunk size, exact ring-wrap
semantics, device retry timing, cursor durability and whether an unacknowledged END
is retransmitted byte-for-byte have not been established for 41.17.6.0.

### WHOOP 4 battery sources

| Source | Observed layout | Use boundary |
|---|---|---|
| Command 26 | **Observed in device captures:** response body begins with `u16le` tenths of a percent | Primary proprietary state of charge; validate result and body length first |
| Event 3 | **Observed in device captures:** state of charge `u16le/10` at frame 17, millivolts `u16le` at 21, charging bit 0 at 26 | Dense pushed observation; offsets are WHOOP 4 event-frame absolute |
| Command 98 | With a valid cache, result 1 carries 25 bytes: `u8`, seven `u16le`, two `u32le`, then `u16le`; pack voltage in millivolts is the third `u16le` at body offset 5. An empty cache returns result 0 | Cached extended battery record; event 63 is `EXTENDED_BATTERY_INFORMATION`, while event 98 means high-frequency sync disabled |
| Standard Battery Service | **Observed in device captures:** some WHOOP 4 devices report a constant 100 | Do not use as authoritative charge when the proprietary source is available |

No listed source establishes cell health, remaining runtime, charging current,
temperature compensation or calibration accuracy. Conflicting observations should
be retained with source and receive time rather than silently averaged.

<a id="whoop-5mg-version-baseline"></a>

## WHOOP 5/MG

Unless a subsection says otherwise, Format 1, Format 2 and the complete response
bodies below apply to **WHOOP 5/MG 50.42.1.0**. They do
not describe WHOOP 4 merely because some inner packet and command numbers overlap.

### Format 1 framing

All multibyte integers below are little-endian. Offsets are from the beginning of the complete frame.

| Offset | Width | Meaning |
|---:|---:|---|
| 0 | 1 | Start byte `aa` |
| 1 | 1 | Format `01` |
| 2 | 2 | Declared length: complete frame length minus 8 |
| 4 | 2 | Header fields; requests commonly use `00 01`, responses `01 00` |
| 6 | 2 | CRC16 over bytes 0–5 |
| 8 | 1 | Packet type: 35 for a command |
| 9 | 1 | Request sequence |
| 10 | 1 | Command number |
| 11 | variable | Request body, followed by zero padding to a four-byte body boundary |
| end − 4 | 4 | CRC32 over the padded body beginning at offset 8 |

Construct the body as packet type, sequence, command and command-specific bytes; append zero bytes until its size is divisible by four. The declared length is that padded size plus four, and the complete frame size is the padded size plus twelve. Padding is not a semantic argument: an explicit request byte `00` and a missing argument must not be treated as interchangeable merely because padding can make their frames look alike.

The baseline format-1 acceptance constraints require a complete frame longer than 15 bytes, exact agreement between declared and supplied length, and `(declared length − 4)` divisible by four. Do not require one constant value for bytes 4–5. Header CRC is reflected Modbus CRC16, polynomial `0xA001`, initial value `0xFFFF`. Format-1 bodies use the standard reflected CRC32 convention, polynomial `EDB88320h`, initial and final XOR `FFFFFFFFh`, including padding.

Reassemble complete frames first, distinguish outer formats, and validate the exact selected frame. Unsupported format, size, header CRC and body CRC are local failures, **not** command-result values on the wire.

WHOOP 4 uses a separate envelope, specified in the [WHOOP 4 envelope](PROTOCOL_WHOOP4.md#whoop-4-envelope).

### Responses and correlation

A format-1 command response has type 36 at offset 8, a generated response sequence at 9, command at 10, **originating request sequence at 11**, result at 12, and command body at 13. The request-origin byte is the correlation field; the response frame's sequence is not the request echo. Match command and origin, with connection/session context and a bounded outstanding-request policy. Sequence wrap and duplicate responses remain possible. WHOOP 4's corresponding command/origin/result/body offsets are 6/7/8/9.

| Result | Meaning | Application consequence |
|---:|---|---|
| 0 | Failure | Preserve the refusal; do not infer its cause without command-specific information. |
| 1 | Success | Request accepted at that command's response boundary; not proof of completed asynchronous work, sensor initialization, live packets or durable storage. |
| 2 | Pending | Keep the request open for its later result within a bounded client timeout. |
| 3 | Unsupported | This command is not supported in the applicable command context. |
| Other | Unknown | Preserve the numeric value; do not coerce it to success. |

Check lengths before accessing the response prefix or body; the CRC trailer and outer padding are not response fields. The first command-body byte is command-specific: for several revision-1 controls it is a revision marker, whereas command 26 begins a four-byte whole-percent value in this version. It is not a universal success flag or state echo. For WHOOP 5/MG 50.42.1.0, the 88 `U` command IDs return result 3 with an empty semantic body command context.

The request sequence is eight bits and can wrap. Sequence reuse across a disconnect
does not prove that a late notification belongs to the new session. A command can
produce multiple responses, and a retransmitted request is not automatically safe
to execute twice.

### Format 2 boundary

A second outer format exists, but its runtime availability and session negotiation are unresolved. Observed ordinary traffic uses format 1; do not assume format 2 without an established session condition. For incoming format-2 commands, inner type 7 is at offset 25, the normalized request sequence comes from byte 17, command from byte 29 and payload starts at 31. The wider outgoing fields do not establish a wider incoming command namespace.

| Reply offset | Width | Meaning |
|---:|---:|---|
| 8 | 1 | Outer type `0x40` |
| 9 | 1 | Revision 1 |
| 11 | 4 | Seconds |
| 15 | 2 | Fractional ticks |
| 17 | 4 | Generated response sequence |
| 25 | 1 | Inner response type 8 |
| 26 | 1 | Zero |
| 27 | 1 | Revision 1 |
| 28 | 2 | Command |
| 30 | 4 | Originating request sequence |
| 34 | 1 | Marker 3 |
| 35 | 4 | Result |
| 39 | 1 | Marker 1 |
| 40 | variable | Command response body |

Unassigned gaps are zero in this reply layout. Reply lengths above 255 bytes are not documented for this format. This is not an unrestricted large-payload interface; behavior for oversized bodies remains unresolved. Format-1 offsets must never be applied to this format.

### Clock and identity contracts

SET_CLOCK uses revision 1, Unix seconds `u32`, and fractional ticks `u16` in units of 1/32768 second. Use a canonical fractional value 0–32767. The stored clock precision is hundredths: the fraction is converted using `floor(ticks × 100 / 32768)`. The reply is a one-byte revision-1 body with success or failure. Behavior of noncanonical fractional values is not specified here.

GET_CLOCK takes revision 1 and returns seven bytes: revision, seconds `u32`, fractional ticks `u16`. Returned ticks are `floor(hundredths × 32768 / 100)`, so a set/get round trip can lose precision. An unsupported revision returns failure with revision 1 and zero time. A clock-read failure can also produce zero time with a success result; there is no independent validity flag. Applications must not treat success alone as proof of a valid wall clock.

A time set while the strap is unavailable can be stored and applied later. Such a
stored time is only applied when its seconds are strictly above Unix timestamp
`1293840001` and newer than the strap's current valid seconds; these comparisons
use seconds, not the fractional field. The stored time is applied at most once,
whether or not the application succeeds. Applications should read the current
device time after reconnecting before relying on it for scheduled operations. A
stored pending time is not a guarantee that the clock was restored or that the
attempt will be repeated.

The deprecated low-number clock pair has different legacy request shapes. Do not substitute its seconds-plus-four-zero-bytes body or its WHOOP 4 response offsets for the new pair.

LINK_VALID returns success with a fixed 13-byte NUL-terminated acknowledgement; it is not an identity token. GET_HELLO accepts revisions 1 and 3, initially returning pending with respectively 107 or 111 body bytes, the revision echoed and other bytes zero. Invalid revision returns failure with a 107-byte body beginning with revision 1. The final layout is specified below; earlier Hello decoder offsets are not universal. Hello and battery-pack records may contain identifiers; a protocol decoder should extract only the fields needed by its feature.

### History sequencing and storage ownership

The boundaries in this section are the operational history contract. WHOOP 5/MG
requests the range before history, while WHOOP 4 can request history directly.
The current range request first returns pending with an empty body; its final
65-byte body is specified below, with opaque cursor and timestamp roles retained.
Lack of a response does not mean that history is empty.

History transmission uses an explicit `00` request byte. Metadata start/end/complete values are 1/2/3. Packet types 49 and 56 both participate in known history routing; the current START/END/COMPLETE path uses type 49; other-version routing remains separately scoped. A command acknowledgement is not delivery of a chunk.

For each HISTORY_END, preserve its eight-byte acknowledgement block verbatim. The first four bytes are the trim cursor in known layouts; the second four reflect write-wrap state in this version. Send the history-result body `01` followed by that block **only after committing** the chunk's decoded records, rejected-record diagnostics and cursor locally. Do not reconstruct that block from decoded timestamps. Maintain arrival order where duplicate handling and cursor association depend on it.

A successful chunk acknowledgement can allow the strap to reclaim history. Local storage failure therefore withholds it. An end marker closes a chunk; transfer-complete closes the overall session. Timeouts do not authorize acknowledging an uncommitted open chunk. Cross-disconnect replay guarantees remain unknown. ABORT_HISTORICAL_TRANSMITS is a stop request, not a trim, and local cleanup must not depend on a reply arriving. FORCE_TRIM and SET_READ_POINTER are separate invasive cursor mutations and are not substitutes for normal chunk acknowledgement.

### Scheduled-control timing

The [high-frequency sync scheduler](PROTOCOL_COMMANDS.md#high-frequency-sync-scheduler)
compares wall-clock seconds for its duration, while its period is measured separately.
It schedules events; it is not a demonstrated Bluetooth throughput control. Command
96/97 and events 96/97/98 occupy separate namespaces.

[Alarms](PROTOCOL_ALARMS.md) likewise compare whole wall-clock seconds for due status.
Clock validity, stored configuration, command acknowledgement and eventual physical
execution are distinct. Preserve the pending/final RUN response sequence and do not
assume that manual RUN leaves the saved schedule intact.

### Complete response bodies

Offsets in the following tables begin after command, origin sequence and result. Lengths exclude framing, CRC and padding. All integers are little-endian. Pending is not completion.

<a id="battery-level--command-26"></a>

#### Battery level — command 26

The final response body is **four bytes**, an unsigned whole-percent value.
The fractional part is discarded. A successful response carries result 1;
an error reply carries result 0 and four zero bytes; a measurement timeout is not confirmed to produce that reply. A zero value
can also be a conversion fallback, so it does not by itself prove a depleted
battery. Do not interpret this version's logical body as a one-byte response.

<a id="hello--command-145"></a>

#### Hello — command 145

Send revision 1 or 3. Initial PENDING has a zero-filled body except the revision:
107 bytes for revision 1, 111 for revision 3. Unsupported request revisions return
FAILURE with revision 1 and 106 zero bytes. Final supported responses have the
following layout. Identity blocks can contain personal device information;
applications generally need selected identity/version fields, not a raw body dump.

| Offset | Width | Field |
|---:|---:|---|
| 0 | 1 | Revision 1 or 3 |
| 1 | 4 | Battery, tenths of a percent |
| 5 | 1 | Opaque state byte |
| 6 | 4 | Unix seconds |
| 10 | 4 | Fractional ticks, units 1/32768 second |
| 14 | 11 | Identity text block A |
| 25 | 24 | Opaque identity block |
| 49 | 30 | Identity text block B |
| 79 | 4 | Version-specific word, value 13 |
| 83 | 4 | Opaque cached word |
| 87 | 4 | Opaque state word |
| 91 | 3 | Version components 50, 42, 1 |
| 94 | 4 | Version suffix 0 |
| 98 | 3 | Opaque three-byte field |
| 101 | 1 | Profile/configuration value, 0–2 |
| 102 | 1 | Opaque cached state byte |
| 103 | 4 | Preparation status bits |
| 107 | 4 | Revision 3 only: opaque cached state word |

The final reply reports SUCCESS even if preparation status bits are set. Retain
those bits and do not assume every field is valid merely because the result is 1.
Preparation bit `0x10` indicates that identity block A could not be filled, and
`0x20` indicates the same for identity block B. Revision 3 can additionally
set `0x40`; that bit's full meaning remains unresolved. Other preparation bits must also be preserved.
Revision 3 adds the trailing word and an additional preparation-status check.
The fractional field occupies four bytes despite the underlying clock fraction
having only 16 significant bits. Text blocks must be bounded by their field width.
The legacy command 35 has no documented reply on 50.42.1.0; do not
use it as an interchangeable command-145 request.

<a id="battery-pack--command-151"></a>

#### Battery pack — command 151

This contract maps to the [LC709205F fuel gauge](PROTOCOL_WHOOP5.md#whoop5-lc709205f).
Send revision 1. The immediate response reports cached information, with SUCCESS
even when no pack is present. Its body is 28 bytes. Other request revisions return
FAILURE with revision 1 and 27 zero bytes.

| Offset | Width | Field |
|---:|---:|---|
| 0 | 1 | Revision 1 |
| 1 | 1 | Presence flag |
| 2 | 6 | Address/identifier block |
| 8 | 16 | Serial/text block; handle as bounded bytes |
| 24 | 2 | Charge value; scale requires separate confirmation |
| 26 | 1 | Opaque cached field |
| 27 | 1 | Opaque cached field |

A successful response is not a live query or a freshness guarantee.

<a id="data-range--command-34"></a>

#### Data range — command 34

An empty PENDING body precedes completion. Final SUCCESS contains revision 1
followed by 16 unsigned 32-bit fields, totalling **65 bytes**. Failure, including
the response timeout path, returns revision 1 followed by 64 zero bytes.

| Offset | Width | Field |
|---:|---:|---|
| 0 | 1 | Revision 1 |
| 1 | 4 | Ring boundary A; full oldest/erase role unresolved |
| 5 | 4 | Read-page cursor B |
| 9 | 4 | Write-page cursor C |
| 13 | 4 | Acknowledged/trim boundary D |
| 17 | 4 | Write-wrap state/count |
| 21 | 4 | Ring capacity in page slots |
| 25 | 4 | Record-count estimate; may fall back to 15 records per page |
| 29 | 4 | Derived quantity: 15 × (adjusted D + capacity − adjusted C) |
| 33, 37 | 4 each | Clock pair from boundary-A page |
| 41, 45 | 4 each | Clock pair from trim-side page, preceding page if equal to write |
| 49, 53 | 4 each | Clock pair from read-side page, preceding page if equal to write |
| 57, 61 | 4 each | Clock pair from last-written page |

For the derived quantity, C and D are each increased by capacity if below A.
The record-count estimate is zero when adjusted trim and write positions coincide.
On the successful record-sequence extraction path, it is the greater of the
unsigned 32-bit expression current sequence − extracted sequence + 1 and the page
distance. Other paths use fallback estimates, so this is not an exact record count
or an all-path formula.
For accepted format-1 records, the first three clock pairs use the inner record
clock for packet 47 and the header clock for packets 48 and 54. Unsupported
header/type combinations yield a zero pair. The last pair prefers the page's
stored final clock and uses a compatible record/header fallback only when both
stored components are zero. These fallbacks do not establish valid dates.

The second member of each pair is a 16-bit value widened to 32 bits. Boundary A and the complete units of every retained clock form remain unresolved. Treat the estimates as counts/distances, not durations. Failed page reads produce seconds-like 0xffffffff and widened companion 65535; unsupported headers can produce zero pairs. The history contract below specifies local retries and current type-49 routing without a universal cross-version guarantee.

### Historical synchronization: boundaries, retries and range interpretation

On the wire, a history command response is an acceptance
result, separate from the history stream. START opens the stream, END marks a
consumer acknowledgement boundary, and COMPLETE closes the current attempt.
Completion alone is insufficient to assert that every stored record has reached
persistent application storage. Use saved progress and the available range to
decide whether another bounded attempt is useful.

Observed traffic for this version uses metadata type 49 for START, END and
COMPLETE. This does not establish a universal boundary between types 49 and 56.
Keep support for other metadata routes where independently required by
supported-device observations.

An END token contains eight bytes. Keep and echo the entire original token after
persisting both the completed chunk and its local progress marker. The first word
is a read-page position modulo ring capacity; the second reflects write-wrap state.
The ordinary acknowledgement path uses the first word for its boundary operation,
but this does not make the trailing bytes optional. Do not construct a replacement
token from an independently saved cursor.

For an ordinary END token, the first word advances the acknowledged/trim boundary
within the ring capacity. Across a wrap, the resulting position remains within
that capacity; when write-wrap state is zero, a target ahead of the current write
position advances only to that write position. Echo the original END token unchanged.

Special tokens are separate from ordinary chunk acknowledgements. With a first
word of `0xffffffff`, the strap signals completion without advancing the ordinary
boundary. A pair of `0xfefefefe` words selects a special mode in which the current
write-page position is used. A pair of `0xfdfdfdfd` words clears that mode and
restores a separately retained history boundary before the next boundary update.
The complete retention role of that second boundary is unresolved. While the
special mode remains selected, an ordinary pair also uses the current write
position. These are observable wire controls, not replacement tokens to synthesize
for a committed chunk, nor a validated recovery or erase procedure.

History delivery emits positive-length, already-framed records only up to 2,140
bytes. Zero is handled separately. This is a record-delivery bound, not the BLE
MTU or a maximum for every protocol packet.

The device has bounded local retries. An unanswered END is resent up to four
times before the transfer leaves the END wait. A repeated END may carry a new
clock value while preserving its token. A non-success acknowledgement does not
perform the normal boundary operation, and the fifth such outcome ends the
attempt. Neither branch provides an exactly-once delivery promise across
disconnects. The application should tolerate
repeated boundaries and records, retain arrival order, and stop an incomplete
attempt without acknowledging data it could not persist.

The read cursor and the acknowledged/trim boundary are separate. A page that
cannot be read is reported as an error and is not necessarily re-sent: the read
position can move past it. That does not prove physical deletion or advancement
of the acknowledged boundary. Preserve decode/read failures as part of
synchronization diagnostics.

The extended range response contains page positions, capacity, estimates and four
clock pairs. Read and write positions are page slots, not timestamps. The selected
ring uses 4096-byte page slots, which can contain multiple records. The count
estimate can fall back to fifteen records per page, so it should not be treated as
an exact number of application rows or a duration. The clock pairs are selected
from a boundary page, the trim-side page, the read-side page, and the last written
page. Empty-side cases can select the preceding page. Failed reads use an all-ones
six-byte sentinel; its two-byte companion becomes 65535 when widened for the
response. Keep sentinel and zero fallbacks separate from usable time values.

### Battery replies and cached accessory information

The battery request returns a percentage that is measured for the request rather
than read from a cache. A measurement timeout is not confirmed to produce the
ordinary percentage reply, so the documented failure-body layout does not
establish a guaranteed battery reply after every timeout. Correlate the requested
command and apply a bounded client wait.

Battery-pack information is cached. Both the full accessory record and its smaller
charge update copy received values without local scale conversion. The strap-side message contract alone does not independently establish a physical percentage
scale for that raw charge value. Preserve the raw value and apply only a separately
verified interpretation. A successful cache query is not proof of a live accessory
measurement or freshness.

### Interruption and recovery

In this version, a fresh history attempt starts again from the acknowledged
boundary when the stored positions are valid. Previously received but
unacknowledged records can therefore recur. START can still appear when that
restoration did not succeed, so it is not proof of the restored position.

Connection loss ends preparation, streaming or END wait. COMPLETE can still be
emitted when the reported backlog is at most six; its appearance proves neither
delivery nor that all records were acknowledged. Reconcile completion metadata
with persisted progress and backlog. On the fifth END-wait timeout the attempt
ends; a later attempt can replay from the acknowledged boundary. Earlier timeouts
resend END while the transfer remains open.

Persist data before ACK, retain the complete original token and tolerate duplicate
records. After reconnect, enable the required notification channels again and
reconcile requested collection with actual output; restoration of every sensor
request is not established.

Connection loss, a Bluetooth controller restart and a full client restart are
distinct operations. None proves that previous temporary sensor requests were
restored. Re-establish temporary collection and live-output requests explicitly;
persistent or continuous preferences can remain separate.
Temporary silence does not prove acquisition or history
recording stopped. Track persistent collection preferences separately from
temporary collection requests.

Connection establishment is not an acknowledgement that ECG or sensor sessions
were restored. Avoid blindly resending ECG start; [repeated starts](PROTOCOL_ECG.md#repeated-ecg-start-and-companion-collection)
can lose the record used for companion collection cleanup.

### Connection and error recovery boundaries

Connection establishment is not a sensor-session restoration acknowledgement. It
does not establish that the app's previous ECG or raw-sensor requests have been
restored.

Diagnostic records are best-effort signals of lifecycle activity and can be
dropped under load. Missing diagnostic records therefore do not prove that
an error or connection transition did not occur, and a recorded event does not
certify durable storage.

Recovery behavior after a link error is not fully documented; do not assume a
disconnect resets sensor sessions. Error handling is conditional, and an ordinary
link loss is treated differently from other error reasons. Do not treat every
disconnect as an application reset or as a request that clears all sensor
sessions. Neither a recovery attempt nor a new connection certifies acquisition
state, completed reboot or durable storage, and no application acknowledgement
reports that a recovery finished.
