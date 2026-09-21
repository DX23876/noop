# WHOOP alarm configuration and execution

Applicability: [central scope and compatibility](PROTOCOL.md#scope-and-compatibility).

This companion to the [command reference](PROTOCOL_COMMANDS.md#haptics-and-alarms)
separates the WHOOP 4 contract below from the later reference baseline. Neither
generation's command acknowledgement alone establishes a successful physical wake.

<a id="whoop-4-alarms"></a>

## WHOOP 4

WHOOP 4 uses the same numeric alarm-family IDs as later devices but different
revision bodies. The statements below describe version-bounded device observations
and supported interoperability behavior; they must not be mixed with the revision-4/revision-2 baseline
later in this chapter.

| Command | WHOOP 4 request body | Validation and boundary |
|---:|---|---|
| 66 SET_ALARM_TIME | `01 \|\| epoch_seconds:u32le \|\| subseconds:u16le` (7 semantic bytes) | **Documented for this version:** working requests observed in device captures appended two zero bytes that are not evaluated. A seven-byte request was acknowledged but did not vibrate; that observation concerns the subsecond field and does not make the semantic body nine bytes. |
| 67 GET_ALARM_TIME | `01` | **Field captures + supported behavior:** used as readback; response layouts vary/are incompletely mapped, so raw payload is retained and no behavior depends on it |
| 68 RUN_ALARM | `01` | **Observed supported behavior:** paired with preset haptics for an immediate user buzz; completion semantics remain incomplete |
| 69 DISABLE_ALARM | `01` | **Supported behavior:** disarms the legacy slot when the command reaches a connected strap; a failed request leaves the strap possibly armed |
| 79 RUN_HAPTICS_PATTERN | `02 03 00 00 00` for the proven preset | **Observed supported behavior:** preset 2, three loops, used for the graduated alarm buzz |
| 80 GET_ALL_HAPTICS_PATTERN | legacy read operation | **Known operation:** complete response vocabulary and physical mapping unresolved |
| 122 STOP_HAPTICS | `00` in the legacy request | **P / U · implemented by NOOP outside the documented 41.17.6.0 command set:** stops an in-progress haptic request; asynchronous completion and every firmware state are not mapped |

### Scheduled alarm lifecycle on WHOOP 4

1. Confirm that command responses can arrive; a
   Bluetooth connection alone is not proof that alarm responses can arrive.
2. `SET_CLOCK` and `GET_CLOCK` are outside the documented 41.17.6.0 command set.
   On some devices one of the two SET_CLOCK forms was observed to latch; read back
   to confirm. A correct clock remains a separate prerequisite.
3. **Observed request:** send command 66 with the seven-byte semantic body; the
   working request form appends two zero bytes that are not evaluated. The epoch
   is the absolute UTC instant corresponding to the user's chosen local wake time;
   subseconds and the appended bytes are zero in the observed form.
4. Request command-67 readback and retain raw bytes, result and
   device identity. An acknowledgement without matching readback does not prove
   persistence.
5. **Device report + event capture convention:** event 57 identifies strap-driven
   alarm execution. It is stronger than SET acknowledgement but still does not
   measure motor force or prove that the wearer woke.

The observed nine-byte request form is a working encoding of the seven-byte
semantic body plus two unevaluated zero bytes. It does **not** establish multiple alarm slots,
recurrence, atomic storage, reboot survival on every firmware, daylight-saving
logic, maximum schedule horizon or exact firing latency. A client implements
weekday recurrence by arming the next absolute instant.

### Immediate WHOOP 4 haptics

The observed reliable one-shot path sends command 79 with preset 2/three loops
and command 68 with revision byte 1, both as acknowledged writes. A bare preset
write was reported ignored in one run. The paired observation does not prove that
both commands are universally required by firmware.

Event 60 (`HAPTICS_FIRED`) and event 100 (`HAPTICS_TERMINATED`) exist in the legacy
event vocabulary. Absence of either event is not proof that the motor did not move.
Pattern IDs, loop units, intensity, thermal/current limits, concurrency rules and
the complete command-80 enumeration remain open.

On 41.17.6.0, commands 66–69, 73/74 and 79/80 are supported. SET parses seconds
and subseconds, rejects a past time and stores/enables a valid alarm; pattern
operations validate IDs and cap loop count. This does not establish the exact
request padding for every version, complete response layouts, motor waveform or
physical execution. Command 122 is implemented outside the documented 41.17.6.0
command set, so its behavior remains separately versioned.

<a id="whoop-5mg-alarms"></a>

## WHOOP 5/MG

Alarm configuration supports six IDs, 1–6. SET uses revision 4 and the following 21-byte body; GET takes `[4, ID]` and, for a valid ID, returns the same 21-byte record. Multibyte fields are little-endian.

| Offset | Width | Field |
|---:|---:|---|
| 0 | 1 | Revision 4 |
| 1 | 1 | Alarm ID |
| 2 | 4 | Epoch seconds |
| 6 | 2 | Fractional ticks, using the clock's 1/32768-second convention |
| 8 | 8 | Waveform effects |
| 16 | 2 | Effect-loop control |
| 18 | 1 | Overall repeat count |
| 19 | 1 | Duration |
| 20 | 1 | Crescendo: 0 ordinary pattern, 1 staged crescendo control |

The earlier 20-byte alarm record receives a zero byte at offset 20 from format-1 padding. With the same sequence and other fields, it produces the same padded body as explicitly supplying crescendo zero. The newly described field does not show that earlier transmitted requests were too short or explain an unsuccessful wake by itself.

SET requires seconds strictly later than the strap's current seconds: a larger fractional value within the same second is insufficient. Each effect byte must be at most 251, repeat count must be below 8, and crescendo must be 0 or 1. When repeats equal 7, duration must be 30–120 inclusive; this interval is not imposed for repeats 0–6. An accepted effect or duration is not a guarantee of a useful physical waveform. The full effect vocabulary, physical intensity and every operating limit remain unresolved.

SET's response body is `[4, validation detail]`. This detail is distinct from the outer command result:

| Detail | Meaning |
|---:|---|
| 1 | Input passed validation |
| 2 | Effect byte out of range |
| 3 | Repeat count out of range |
| 4 | Duration out of range for repeat count 7 |
| 10 | Time is not later than the current whole second |
| 11 | Alarm ID out of range |
| 12 | Crescendo out of range |

Validation failures return outer failure. Detail 1 can accompany outer success
**or failure**. A pattern can be stored while the time is rejected, so read back
both parts when their final state matters. The alarm-set event 56 is not independent
proof of persistence. Alarm updates are not established as atomic or power-loss
safe. GET can return zeros after a read failure while still reporting success;
an all-zero time can therefore mean cleared/unset state or a read fallback.
Invalid-ID/revision failure bodies are not usable alarm records.

### Disable, due processing and manual run

DISABLE uses `[2, ID]` for one alarm or `[2,255]` for all six. Its body carries
revision 2. All-ID disable can clear some slots and still return failure when at
least one slot was not cleared; read back individual slots when their state matters.
Disabling clears the saved record; it does not substitute for stopping an already
active haptic effect.

The strap compares an alarm's whole seconds with its clock at a nominal cadence of
about half a second. Fractional ticks are retained but do not make this comparison
subsecond-precise; exact intervals and worst-case latency remain unresolved. A due
alarm is cleared before haptic completion, so it is a **one-shot schedule**, not a
daily recurrence. Clearing can fail separately. When several slots become due
together, the highest ID can be the one executed; independent playback of every
due alarm is not guaranteed.

RUN uses `[2, ID]` and requires an existing nonzero stored time. It does not apply
SET's future-time check. A valid initial response is outer pending with body `[2,0]`;
an invalid or unset ID fails with `[2,11]`. The later response body is `[2, detail]`,
with outer success only when detail equals 5. Timeout returns failure with `[2,7]`;
its duration is not specified here. RUN also clears the selected saved record, so
it is not a guaranteed nondestructive preview of a future schedule.

Strap-triggered execution emits event 57; client-triggered RUN emits event 58.
Ordinary patterns and crescendo can produce different results. These events identify
execution attempts; they do not independently prove motor movement or that a person
woke up. Concurrent activity and full crescendo timing remain unresolved. Earlier
alarm arming acknowledgements do not establish an observed strap-driven wake.

### Busy execution and stop completion

When multiple alarms become due together, later slots can supersede earlier ones;
separate execution of every due alarm is not guaranteed. Avoid overlapping schedules
and overlapping manual haptic requests.

While a haptic is active, a newly due alarm can be cleared without starting a
second vibration, and it can alter the reported active alarm. A successful schedule
write therefore does not guarantee later vibration.

Stopping haptics is asynchronous. Distinguish the initial pending response from
the final result. Stop completion and start completion have different success
conditions; the stop response contains the revision alone. Stopping the current
effect does not disable stored alarms or establish that no pending request remains.

The notification-haptic body contains a revision, eight effect bytes, a
little-endian loop-control field and an overall repeat byte. The start response
contains revision and detail. Preserve the operation-specific response layout.

Crescendo uses staged output. Physical intensity, reliable stage timing and motor
output are not established by an accepted request. Durations below 20 are accepted
when repeats are below 7, but later timing can be irregular; acceptance is therefore
not evidence that a short crescendo setting is safe or useful. A separate total-duration
stop can end the effect first.

Before returning timeout detail 7, the strap can make up to three start attempts.
A client must not interpret each attempt as a separate alarm or issue another
start while awaiting the correlated completion. The first crescendo stage's
duration remains unresolved.

After restart, execution still depends on readable retained schedules and a correct
clock. Reboot survival and wake latency require separate validation. No automatic
ECG or sensor-request cleanup on disconnect is promised.

Command 122 takes revision 1 alone. Initial pending and final success/failure all carry the one-byte body `[1]`; unsupported revision also fails with `[1]`. The final result is operation-specific and must not be inferred from the start response detail. Command 19 takes 12 bytes and returns revision plus detail; its final success uses detail 5, as does manual RUN.

The observed single-notification command-19 body is `01 2F 98 00 00 00 00 00 00 00 00 00`:
revision 1, effects `[47,152,0,0,0,0,0,0]`, zero effect-loop control and zero repeats.

The alarm scan runs at a nominal half-second cadence. This is not an exact
free-running scan period, motor-start deadline or wake guarantee: the actual
interval can vary with oscillator error and scheduling on the strap.
