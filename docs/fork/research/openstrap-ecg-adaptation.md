# OpenStrap ECG implementation and adaptation to ryanbr/noop — full technical report

Reviewed: 2026-09-29. Status: source comparison complete; adaptation not implemented.

Published upstream: [ryanbr/noop issue #891, source-comparison comment](https://github.com/ryanbr/noop/issues/891#issuecomment-5889235150). The report targets `ryanbr/noop`; Apple-specific findings are identified explicitly.

Analysis migration required: no

This is source research only. It changes no application behavior or stored analysis. No MG hardware was available for this review. The findings identify shipped implementation and reproducible decoder gaps; BLE behavior on another MG/firmware remains a separate integration check.

My MG is expected later this week, so an independent hardware test is still pending. This report complements the existing [ayiskakov hardware report](https://github.com/ryanbr/noop/issues/891#issuecomment-5803472142) and [meta1971 framing/wrist findings](https://github.com/ryanbr/noop/issues/891#issuecomment-5803289538). Findings below distinguish inspected implementation, executed synthetic checks, attributed hardware reports and proposed changes.

## Reading map

1. Pinned versions and existing upstream work.
2. Released OpenStrap commits and NOOP's existing capabilities.
3. Concrete Apple integration gaps and the R17 packet layout.
4. OpenStrap transport, command acknowledgements, capture state and persistence.
5. Adaptation sequence, firmware/provenance boundaries and validation requirements.
6. Executed Swift reproduction, exact output and instructions to reproduce it.

## Pinned scope

- RyanBR NOOP: `903166d252ef54b3b931d8cd9af7095365f63b0b`, rechecked before publication.
- Initial comparison baseline: `0c9828998717544875f2b95f538942a39c3cf4ce`; older immutable references below retain that context.
- OpenStrap Edge release: `v0.10.0+66`, commit `71b7761bb05b11ec1d4533caf2b035ceb30bc9ae`.
- OpenStrap protocol dependency used by that release: `bc7d8d0df706e40a2546ffde4545263f09d0fecb`.

The tested Swift ECG decoder is byte-identical to the current `ryanbr/noop` file. The latest Apple source was rechecked for command sequencing, candidate decoding, MG eligibility and raw-IMU dispatch. [PR #2590](https://github.com/ryanbr/noop/pull/2590) is merged and adds a conditional `abortBackfill()` before the ECG toggles. [PR #2591](https://github.com/ryanbr/noop/pull/2591) is open (reviewed head `427bbe39602c5820798fdad10abf50af2a5638c5`) and adds per-device latch persistence with manual Stop; automatic reconnect cleanup is explicitly outside its scope. The comparison accounts for both changes. The Apple-specific gaps below are not a claim that every Android path has the same gaps; protocol/storage changes intended for this repository require its Swift/Kotlin parity review.

## Conclusion and links to share

**OpenStrap ships an integrated MG ECG feature that is a concrete reference for adapting NOOP.** Its released app connects real BLE transport, an R17 decoder, capture/contact state, live waveform, local persistence and saved-reading detail. NOOP already has the start/stop command values, but its Apple path is still a research probe with incompatible decoding and incomplete session management.

The [feature PR #367](https://github.com/OpenStrap/edge/pull/367) merged on 2026-09-22, and [v0.10.0](https://github.com/OpenStrap/edge/releases/tag/v0.10.0) was published on 2026-09-25. The release's [protocol lock entry](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/pubspec.lock#L945) pins the implementation inspected here. Useful links for a maintainer:

- [BLE transport commit `e78df606`](https://github.com/OpenStrap/edge/commit/e78df606483e9db49387ec11dc20db9a5c7f2a33): the command sequencing, capture lease and recovery integration.
- [Complete feature merge `11c78312`](https://github.com/OpenStrap/edge/commit/11c78312cbc5186433135fd7be58a9cdebb4e526): the integrated app feature, also navigable through PR #367.
- [Protocol implementation commit `4aa36fae`](https://github.com/OpenStrap/protocol/commit/4aa36faefd9c52b7982cb64896a92d9932637df9): R17/R16 structures and control builders, merged through [protocol PR #54](https://github.com/OpenStrap/protocol/pull/54).

The PR author reports running the feature on a physical MG: successful PREPARE/START replies, parsed live R17 at 100 samples/s, contact handling and cleanup followed by sync. That is an attributed hardware report. The application wiring and packet/control implementation below were independently inspected in the pinned released source.

## What NOOP already implements

NOOP already sends the corrected generation argument: `124 = 2` starts and `124 = 1` stops. Its own source records the successful combination `139 = 1`, then `124 = 2` on an MG `WS50_r00`, firmware `50.39.1.0`. The command payload is a revision byte followed by the argument, and framing/CRC construction is shared with other WHOOP 5 commands. This is already implemented, not something OpenStrap newly supplies to NOOP. [Control values and provenance](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift#L287), [literal command tests](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5EcgTests.swift#L398).

NOOP's `puffinCommandFrame` also already pads the inner record to a four-byte boundary. The unpadded-frame failure reported by an independent client in this issue must not be attributed to NOOP's existing builder. [NOOP framing implementation](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift#L304).

The Apple app includes a reachable ECG research probe. Devices enables it for an active connected WHOOP when the Test Centre Connection domain is active, ECG is opted in (or a prior capture may still be running), and the device is recognized as an MG. The sheet offers start, stop, a separate wrist selection, and a text result. The BLE entry points additionally require an encrypted bond. This is a command-and-log probe, with no ECG waveform view or structured ECG session persistence found in the Apple source. [Device entry gate](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/Screens/DevicesView.swift), [actions and result](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/Screens/DevicesView.swift), [BLE gates](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift), [text-only live state](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/LiveState.swift).

The separate persistent `enable_raw_data_w_ecg` gate is not the ECG session controller. It writes the config value and reads it back, with its own opt-in and MG gate. A read-back confirms that config value, not ECG acquisition. It must not be presented as the missing condition OpenStrap has proven necessary. [Gate implementation](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift).

## Concrete gaps in the Apple NOOP path

### Two existing decoders must be distinguished

NOOP has **two distinct decoder paths**; describing the entire implementation as starting samples at byte 28 would miss the second one:

| Path | Actual implementation | Consequence for adaptation |
|---|---|---|
| Active Apple probe | `decodeFilteredFrame` starts at frame byte 11 and reads an unpacked 17-byte status header; samples therefore start at byte 28. `plausibleFilteredFrame` uses the same layout. The probe calls these helpers directly. | This path does not represent the released OpenStrap R17 layout. Changing only the sample offset would leave status, declared count, revision and packet identity wrong. |
| Separate type-43 sample helper | Requires frame length 240 and type 43. Starts at byte 34 and reads through byte 235, yielding exactly 101 signed samples. Does not validate revision or declared count. | The start offset already exists, but the helper includes the alignment word and cannot implement a count-aware R17 decoder. No production Apple caller was found. |
| OpenStrap released R17 parser | Requires type 43 and revision 17; stored type 47 is opt-in. Reads declared count at inner 24 / full-frame 32, rejects counts above 100, and reads exactly that count from inner 26 / full-frame 34. Preserves remaining bytes. | Provides the complete packet structure and dispatch rules to reimplement in the pure NOOP package. |

Sources: [NOOP generic status](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift#L130), [generic payload offset](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift#L240), [generic decode](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift#L393), [active Apple caller](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift#L4563), [separate sample helper](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift#L528), [OpenStrap R17 parse](https://github.com/OpenStrap/protocol/blob/bc7d8d0df706e40a2546ffde4545263f09d0fecb/lib/src/labrador.dart#L163).

NOOP's newer protocol document already describes the packed 13-byte status region at frame bytes 21–33, 100 sample slots at 34–233 and alignment bytes 234–235; it explicitly warns against interpreting 101 samples. The source and tests have not caught up with that document. This is evidence of an implementation gap, not evidence that the entire NOOP project lacks the protocol knowledge. [NOOP protocol document](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/docs/PROTOCOL_ECG.md#L125).

### Status fields are packed, not four successive boolean bytes

For a full WHOOP 5 frame the released OpenStrap parser reads:

| Frame offset | OpenStrap R17 interpretation |
|---:|---|
| 8 / 9 | Packet type / data revision |
| 10 | Secondary packet-context byte, retained without assigning ECG status semantics |
| 11–14 | Acquisition-cycle sequence, u32 LE |
| 15–18 / 19–20 | Strap seconds / subseconds |
| 21 | Quality |
| 22 | Packed flags: enter state 1, current state 1, transition 1→2, presence |
| 23 / 24 / 25 | Result / state / progress |
| 26 | Unreadable-reason mask |
| 27 / 28 | Average / live heart rate |
| 29–30 | Variability raw value; `0xffff` means unavailable |
| 31 | Reserved |
| 32–33 | Declared sample count, u16 LE |
| 34 onward | Declared count of signed i16 LE samples, at most 100 |

OpenStrap treats `progress == 100 || state == 2` as terminal and `progress == 255` as invalid. NOOP's existing generic status model has separate `started/running/stopped/leadsOn` bytes and a 17-byte layout. Its generic plausibility test checks those bytes for 0/1, so an incoming R17 frame may be rejected before any candidate is counted. The right correction is a dedicated revision-aware packet model and dispatcher, not moving the generic payload start. [OpenStrap fields, flags and terminal predicates](https://github.com/OpenStrap/protocol/blob/bc7d8d0df706e40a2546ffde4545263f09d0fecb/lib/src/labrador.dart#L26), [NOOP old fields](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift#L156), [NOOP plausibility test](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift#L514).

The full-frame offsets above include the eight-byte envelope; inner-packet offsets are eight smaller. Multi-byte fields are little-endian. OpenStrap computes strap time as `seconds + subseconds / 32768.0`. Its byte-22 masks are bit 0 entering S2 state 1, bit 1 current S2 state 1, bit 2 transition 1→2 and bit 3 electrode presence. Byte 26 is a separate unreadable-reason mask: low amplitude, significant noise, unstable signal and insufficient data in bits 0–3; higher bits retain an unknown-bit label. `tryParseFrame` requires valid frame revision/header CRC/payload CRC before calling the inner parser. Zero-sample boundary packets are valid; a count over 100 or a sample block that exceeds the available bytes is rejected. These are the released parser's semantics, with firmware applicability discussed below. [Parser and status definitions](https://github.com/OpenStrap/protocol/blob/bc7d8d0df706e40a2546ffde4545263f09d0fecb/lib/src/labrador.dart#L26).

### MG attestation can prevent the Apple probe from being offered

The pure `Whoop5Variant.from` resolver already accepts a DIS Model Number of `MG`. Its source records an MG with serial prefix `MGB` and hardware revision `WS50_r03`, which does not match its older prefix heuristics. Apple `BLEManager` calls this resolver with only serial and hardware revision; it reads/logs DIS Model Number but does not supply it. Such a device stays `.unknown`, and `isWhoop5MG` remains false. The source itself acknowledges this unconnected path. This is a concrete eligibility defect separate from ECG command sequencing. [Resolver](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Variant.swift#L71), [Apple gate caller](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift#L1295), [Apple DIS callback](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift#L7209), [acknowledged missing argument](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift#L5254).

RyanBR's Android client already passes `disModelNumber` into the same conceptual resolver. Do not describe this Apple gap as an Android gap. [Android caller](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/android/app/src/main/java/com/noop/ble/WhoopBleClient.kt#L9303).

### Type-43 ECG traffic also reaches the raw-IMU fail-safe

At the current upstream SHA, `stopUnexpectedRealtimeImu` checks WHOOP 5 live packet types 43 or 51, raw capture being off, and its time guards. It does not distinguish revision-17 ECG or an active ECG session. It then sends `stopRawData` and `toggleIMUMode` off. The notification loop invokes this helper before ordinary frame routing. Thus fixing only the ECG candidate decoder leaves an unrelated writer able to send IMU stop commands during ECG traffic. [Guard and writes](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift#L2243), [notification dispatch](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift#L7367).

This source finding agrees with ayiskakov's linked hardware report, which recorded repeated fail-safe writes while ECG continued. It does not establish that those writes invariably terminate ECG. The adaptation should distinguish verified ECG traffic and session ownership while preserving the intended recovery of genuinely orphaned IMU streams. A type-43-wide exemption would be too broad.

### The Apple probe has command logging, not a managed capture lifecycle

At the current upstream revision, NOOP's Apple start conditionally calls `abortBackfill()` and then sends `139=1`, `125=1`, `124=2` consecutively. Wrist selection is a separate action with inferred values `right=0`, `left=1`. The merged history-abort change addresses an active drain. The remaining start path has no exclusive capture ownership, wait for each ECG command response, or rollback after an unsuccessful step. The low-level sender immediately writes the frame with `withoutResponse` by default; that BLE write option is distinct from the later WHOOP command response. [Start and wrist actions](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift#L4395), [wrist values](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift#L275), [send implementation](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift).

The response handler verifies the frame CRCs and supports response types 36 and 38. It matches the first unanswered step by command label/opcode, without correlating the originating sequence. Thus it records the eventual reply but does not use success to authorize the next command. [Response handler](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift#L4503).

The 30-second timer only ends the observation window and writes a text report; it does not stop the stream. Explicit stop sends `124=1`, `125=0`, `139=0` and clears `ecgMayBeRunning` immediately, without waiting for those replies. Turning off the experimental switch invokes stop; dismissing the result clears the text only. Disconnect clears probe bookkeeping. PR #2591 adds persistence of the may-be-running latch across relaunch; the reviewed main branch does not yet include it. A production capture still needs a lifecycle covering terminal status, missing data, command failure, cancel, backgrounding and reconnect, with any automatic writes evaluated against upstream policy. [Timer and stop](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift#L4447), [toggle-off stop](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/Screens/SettingsView.swift), [disconnect reset](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/Strand/BLE/BLEManager.swift).

## Existing test coverage and its limits

NOOP's generic ECG tests explicitly use synthetic unpacked-status fixtures. They cover command bytes, CRC rejection, truncation, signed values and conservative diagnostic verdicts. The type-43 tests also build synthetic frames, assert 101 samples and do not carry a real R17 revision/count/status contract. These tests explain why existing tests can pass while the R17 path remains incomplete. This review inspected the tests; it did not rerun them or claim hardware validation. [Generic test provenance](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5EcgTests.swift#L4), [generic frame fixture](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5EcgTests.swift#L290), [fixed 101-sample test](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5EcgRawRecordTests.swift#L11).

## What the released OpenStrap app does differently

### Identification and exclusive transport ownership

OpenStrap identifies MG through a revision-1 Gen5 HELLO whose optical discriminator is below 38. It then claims a lease tied to both the BLE session and a link-generation counter. Capture work is rejected after that link changes. History ownership is cancelled and allowed to settle before setup; history requests and maintenance writes are held off while ECG owns the transport. This separates ECG from concurrent sync traffic. [HELLO interpretation](https://github.com/OpenStrap/protocol/blob/bc7d8d0df706e40a2546ffde4545263f09d0fecb/lib/src/control.dart#L394), [lease and history handoff](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ble/ble_engine.dart#L1060).

### Command order and response correlation

The actual released app uses this sequence; it is more precise than copying a convenience builder's comment:

| Stage | Commands, in order | Acceptance rule |
|---|---|---|
| PREPARE | `123 [01 wrist]`, `139 [01 01]`, `125 [01 01]` | Wrist is right `01`, left `02`; all three replies must succeed before START. |
| START | `20` abort history, `124 [01 02]` | Abort is sent even if no earlier history task was active; the controller requires the list to succeed. |
| Explicit RESTART | `20`, `124 [01 03]` | Used for a distinct state predicate, not ordinary loss of electrode contact. |
| CLEANUP | `124 [01 01]`, `139 [01 00]`, `125 [01 00]` | Every member is attempted; the durable guard is cleared only when every reply succeeds. |

Each member registers a response waiter **before** the BLE write and matches both sequence and opcode, with a five-second timeout and no automatic resend. Lists use attempt-all semantics: they continue after a failed member while the lease remains valid. In particular, a failed PREPARE prevents entry into START; within the START list, the generation member is still attempted after the abort member. A NOOP port must choose and test its failure policy explicitly. [Lists and execution](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ble/ble_engine.dart#L1123), [waiter before write](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ble/ble_engine.dart#L4611), [wrist values](https://github.com/OpenStrap/protocol/blob/bc7d8d0df706e40a2546ffde4545263f09d0fecb/lib/src/commands.dart#L9).

### Capture state, packet acceptance and recovery

The controller subscribes before starting generation, persists a per-serial may-be-active guard before enabling any stream, and starts a 120-second capture deadline after successful START. It handles cancellation, app pause, disconnect, malformed data and storage failure. One finish path attempts cleanup and releases the screen/transport. Incomplete cleanup remains visible and retains the guard; on the next ready connection, a recovery hook attempts cleanup before normal history resumes. [Begin and subscriptions](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ecg/ecg_controller.dart#L192), [finish path](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ecg/ecg_controller.dart#L509), [durable guard](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ecg/ecg_guard_store.dart#L1), [recovery](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ecg/ecg_recovery.dart#L25).

The reducer distinguishes waiting, active, contact lost and done. Presence plus positive valid progress starts the accepted window. Contact loss, zero progress or regressing progress discards the unfinished window; ordinary contact return resumes without a generation restart. A valid active, nonterminal, nondecreasing packet with presence set but the current-S2-state-1 flag clear takes the explicit restart branch. Sequence jumps insert one missing-segment placeholder, and repeated terminal packets do not save twice. Live preview and the accepted window are separate. [Reducer](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ecg/ecg_policy.dart#L157).

The order of checks matters when porting the reducer:

| Current phase | Checks in implementation order | Result |
|---|---|---|
| Waiting | Accept only `presence && progress > 0 && progress != 255`. | Clear the old window, append the packet and enter active. Other packets leave this phase unchanged; terminal handling is not performed in this branch. |
| Active | First contact/progress loss; then terminal; then invalid progress; then current-S2-state-1 bit. | Loss clears the unfinished window and increments interruptions once. Terminal resolves the reading. Invalid progress fails. Otherwise append if the state bit is set, or clear and request the explicit restart if it is clear. |
| Contact lost | First the same acceptable-start predicate; then invalid progress or interruption count ≥3. | An acceptable packet resumes and is appended without START. Otherwise the failure predicate ends capture; remaining packets leave the phase unchanged. |
| Done | No further reduction. | Repeated terminal packets are ignored. |

These predicates describe the observed implementation, including its ordering; they are not unconditional rules such as “progress 255 fails in every phase” or “any terminal packet immediately saves.” App/controller deadlines operate around this reducer.

There is a relevant source/PR-summary distinction: the third interruption does **not** immediately fail. The reducer first enters contact-lost; the next unacceptable packet fails if the interruption count is at least three. An immediately acceptable packet can recover even then. A port should preserve a deliberately selected rule, rather than turn the PR's shorthand into a different boundary. [Boundary test](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/test/ecg_policy_test.dart#L290).

Terminal handling uses the device result with **live HR** for the immediate category and **average HR** for the persisted category. An unreadable outcome clears the accepted window; the first inconclusive outcome clears it and offers a user retry. A later inconclusive result or a completed result includes the terminal packet and reaches the save path. Gap handling inserts exactly one placeholder whenever `sequence != previous.sequence + 1`; it does not create one placeholder per missing sequence value. These distinctions should be captured in Swift/Kotlin tests before porting category or accumulation behavior. [Terminal and accumulation code](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ecg/ecg_policy.dart#L160).

The controller ignores events from old link generations and ignores frames while unarmed or restarting. Its live preview receives samples from the armed pipeline, including pre-contact zeros, while only the reducer's accepted window is saved. Saving must succeed before the completed phase is published; cleanup runs on that exit too, and a failed cleanup is exposed through `cleanupIncomplete` while the guard stays set. The controller subsequently requests ordinary history sync to collect the saved R16 records. [Frame dispatch](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ecg/ecg_controller.dart#L352), [save and finish](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ecg/ecg_controller.dart#L437).

### Shipped UI and durable records

The ECG screen calls the real controller, previews incoming samples, lists saved readings and opens full-waveform detail. `AppState` supplies the BLE transport and database save callback, as well as workout/breathing exclusion. This verifies that the code is wired into the application. [Screen entry and navigation](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ui2/screens/ecg.dart#L99), [capture start](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/ui2/screens/ecg.dart#L324), [application wiring](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/state/app_state.dart#L196).

Schema version 54 adds three tables: reading summaries, accepted R17 packets (signed i16 LE sample BLOB plus exact inner bytes and gap placeholders), and historical R16 packets retained byte-for-byte. A reading and its accepted packets are saved atomically before completion is presented. Raw R16 records join the normal durable history transaction before acknowledgement; the protocol parser preserves their body without claiming a decoded layout. [Schema and atomic insert](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/data/db.dart#L1753), [history transaction](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/lib/data/db.dart#L3603), [R16 preservation](https://github.com/OpenStrap/protocol/blob/bc7d8d0df706e40a2546ffde4545263f09d0fecb/lib/src/labrador.dart#L223).

The tables are `ecg_reading` (summary/result/provenance), `ecg_reading_packet` (ordered accepted packets, exact samples/inner bytes and gap markers), and `ecg_raw_packet` (historical R16 bytes). A NOOP adaptation should use its own versioned schema rather than copy OpenStrap's migration number. OpenStrap's R16 parser reads only the common sequence/time header; NOOP's ECG document describes an R16 body separately. Do not mistake the scope of OpenStrap's implemented R16 parser for the scope of NOOP's documented protocol knowledge.

## Concrete adaptation plan for NOOP

The following is a recommendation inferred from the compared implementations, not an implemented change.

1. **Correct identification and decoding in the existing path.** Feed DIS Model Number into the existing central MG resolver and update eligibility when it arrives. Use one resolver for UI and BLE. Add a dedicated R17 model in `WhoopProtocol`: CRC-gated frame dispatch, type/revision validation, packed status, declared count bounded at 100, signed samples, retained tail. Correct the wrist values with firmware provenance. Replace the active probe's generic R17 interpretation and retire or correct the 101-sample helper together with its tests. Make raw-IMU recovery distinguish ECG traffic/session ownership while retaining its protection for actual IMU producers. A change of offset alone is insufficient.
2. **Add a testable capture controller shared by the Apple targets.** Build on #2590 and #2591, giving it exclusive ownership relative to history; correlate WHOOP replies by originating sequence and opcode. Model preparation, waiting, contact loss, accepted window, terminal state and cleanup explicitly. Persist the may-be-active guard before writes and clear it only after successful cleanup, with stale-link rejection. Define reconnect recovery in accordance with upstream's explicit restrictions on automatic ECG writes; #2591 intentionally restores manual Stop without sending anything. Keep transport calls behind a narrow interface so timing and failures can be exercised without a strap, and implement the appropriate Kotlin counterpart under the repository's parity contract.
3. **Add local capture/review storage and UI.** Store reading provenance, exact accepted packets and gaps, using a versioned `WhoopStore` migration and an atomic save. Route historical R16 bytes through the existing commit-before-ACK contract. Add a waveform, progress/contact feedback, cancel action and saved-reading detail. Keep any band-reported category distinct from NOOP's computed analytics. Account for new tables in backups and deletion. Changes intended for `ryanbr/noop` require iOS/macOS integration and its Android parity contract.
4. **Validate the hardware-dependent parts on the arriving MG.** Record identification and firmware first. Check wrist acknowledgement, ordered responses, R17 counts/flags, the accepted window and cleanup; then cancellation, contact return, disconnect/reconnect recovery and ordinary sync afterward. A raw capture from that firmware can become a sanitized regression fixture.

Meaningful pre-hardware tests cover counts 0/49/100 and rejection of 101, signed extremes, bad CRC, wrong revision/type, truncation, packed contact/progress fields, wrong-sequence replies, failed setup, frames arriving before the START response, contact-loss boundaries, duplicate terminal packets, failed save, retained guards and replacement links. Build both Apple app targets when production app code changes.

**Analysis migration required: no** for this research and a scoped new ECG capture feature that leaves existing recovery/strain/sleep derivations unchanged. New ECG tables still require an ordinary database migration. If a later change feeds ECG-derived values into existing analysis or changes previously persisted meanings, reassess the analysis migration independently.

### Firmware and provenance boundaries to resolve during the port

- OpenStrap's R17 source cites firmware `50.41.1.0`; NOOP's current ECG document inherits the `50.42.1.0` baseline from `PROTOCOL.md`, and the older probe records `50.39.1.0`. Treat these as explicit evidence versions. OpenStrap accepts variable total packet lengths if the declared sample block fits; NOOP's documented layout describes 240-byte frames. Select the supported contracts explicitly and preserve unexpected bytes for investigation. [OpenStrap provenance and length check](https://github.com/OpenStrap/protocol/blob/bc7d8d0df706e40a2546ffde4545263f09d0fecb/lib/src/labrador.dart#L1), [NOOP baseline](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/docs/PROTOCOL_ECG.md#L1).
- OpenStrap names `124=3` restart; NOOP documents it as another start selector with distinct restart behavior unestablished. Ordinary contact loss already recovers without resending generation. Preserve this distinction and validate the explicit restart case before enabling automatic retries. [NOOP command contract](https://github.com/ryanbr/noop/blob/0c9828998717544875f2b95f538942a39c3cf4ce/docs/PROTOCOL_ECG.md#L40).
- OpenStrap labels samples as 100 Hz, integer input-referred microvolts, with no wrist sign flip; variability has no established physiological unit. Retain original integers and source/firmware provenance. Do not infer anatomical lead, polarity or an HRV unit from those labels. [Sample and variability semantics](https://github.com/OpenStrap/protocol/blob/bc7d8d0df706e40a2546ffde4545263f09d0fecb/lib/src/labrador.dart#L73).
- Both inspected OpenStrap repositories use MIT licenses. Any substantial code port must retain the applicable notice. NOOP's clean-room rules still apply: attribute protocol facts and their evidence status, and do not import vendor firmware or decompiled implementations. This review used public OpenStrap source, not vendor artifacts. [Edge license](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/LICENSE), [protocol license](https://github.com/OpenStrap/protocol/blob/bc7d8d0df706e40a2546ffde4545263f09d0fecb/LICENSE), [NOOP contribution rules](https://github.com/ryanbr/noop/blob/903166d252ef54b3b931d8cd9af7095365f63b0b/docs/CONTRIBUTING.md).

## Validation performed for this review

The OpenStrap protocol and app tests were inspected, not executed. They cover frame bounds and CRCs, command bytes/correlation, reducer boundaries, lifecycle failures and persistence. The public R17 fixtures are explicitly synthetic. The reducer's “86 frames → 30 accepted → 3,000 samples” test constructs packets in code; it is not a published raw hardware trace. Keep that separate from the PR author's physical-MG report. [Protocol fixtures](https://github.com/OpenStrap/protocol/blob/bc7d8d0df706e40a2546ffde4545263f09d0fecb/test/labrador_r17_test.dart#L1), [transport tests](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/test/ecg_ble_engine_test.dart), [controller tests](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/test/ecg_controller_test.dart), [synthetic accepted-window scenario](https://github.com/OpenStrap/edge/blob/71b7761bb05b11ec1d4533caf2b035ceb30bc9ae/test/ecg_policy_test.dart#L405).

### Executed Swift reproduction

A temporary Swift executable was built against the `WhoopProtocol` source package. The tested ECG decoder was verified byte-identical to the current `ryanbr/noop` file before publication. It constructed 240-byte type-43/revision-17 frames with valid CRCs, a packed presence/current-state flag, and declared counts 0, 49, 100 and 101. The last is deliberately invalid under the OpenStrap contract. The resulting output was:

```text
declared=0 frameBytes=240 crc=true probePlausible=false genericSamples=0 rawSamples=101 rawLast=0
declared=49 frameBytes=240 crc=true probePlausible=false genericSamples=0 rawSamples=101 rawLast=0
declared=100 frameBytes=240 crc=true probePlausible=false genericSamples=0 rawSamples=101 rawLast=0
declared=101 frameBytes=240 crc=true probePlausible=false genericSamples=0 rawSamples=101 rawLast=0
MG without model=unknown, with model=mg
```

The active probe rejects all four fixtures; calling its generic decoder directly produces zero samples because it reads the wrong count field. The separate helper returns 101 samples in every case, including padding. The resolver reproduces the missing-model-number eligibility problem. These are local executable results over constructed data, not an ECG measurement or a run of the OpenStrap implementation.

Reproduction source (`main.swift` in a temporary executable target depending on the local `WhoopProtocol` package):

```swift
import Foundation
import WhoopProtocol

func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
    bytes[offset] = UInt8(value & 255)
    bytes[offset + 1] = UInt8((value >> 8) & 255)
}
func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
    for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 255) }
}
for count in [0, 49, 100, 101] {
    var inner = [UInt8](repeating: 0, count: 228)
    inner[0] = 43; inner[1] = 17
    put32(&inner, 3, 23940969); put32(&inner, 7, 1787823784)
    put16(&inner, 11, 12345)
    inner[13] = 1; inner[14] = 0x0a; inner[16] = 1; inner[17] = 3
    inner[20] = 70; put16(&inner, 21, 65535); put16(&inner, 24, count)
    for index in 0..<min(count, 100) {
        put16(&inner, 26 + 2 * index, index + 1)
    }
    let frame = puffinCommandFrame(
        cmd: inner[2], seq: inner[1],
        payload: Array(inner.dropFirst(3)), type: inner[0]
    )
    let generic = Whoop5Ecg.decodeFilteredFrame(frame)
    let raw = Whoop5Ecg.realtimeRawSamples(frame)
    print("declared=\(count) frameBytes=\(frame.count) crc=\(verifyFrame(frame, family: .whoop5).ok) probePlausible=\(Whoop5Ecg.plausibleFilteredFrame(frame)) genericSamples=\(generic.map { String($0.filteredECGDataRaw.count) } ?? "nil") rawSamples=\(raw?.count ?? -1) rawLast=\(raw?.last ?? -999)")
}
print("MG without model=\(Whoop5Variant.from(serial: "MGBexample", hardwareRevision: "WS50_r03").rawValue), with model=\(Whoop5Variant.from(serial: "MGBexample", hardwareRevision: "WS50_r03", modelNumber: "MG").rawValue)")
```

To reproduce, put that `main.swift` in `Sources/` of a temporary directory containing this `Package.swift`. Replace the dependency path with a checkout of `ryanbr/noop` at the pinned SHA above; the manifest path is a placeholder, not a user-specific location:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EcgRepro",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "/absolute/path/to/noop/Packages/WhoopProtocol")
    ],
    targets: [
        .executableTarget(
            name: "EcgRepro",
            dependencies: [
                .product(name: "WhoopProtocol", package: "WhoopProtocol")
            ],
            path: "Sources"
        )
    ]
)
```

Run from that temporary directory:

```sh
swift run EcgRepro
```

This builds the source package and the reproduction executable without changing NOOP's production source. The executed run used temporary build/cache directories because of local filesystem restrictions; those cache locations are not part of the test. The output above is the actual observed result, not an expected-output assertion generated from the proposed new decoder.

No production code was modified, no full app build or full package test suite was run, and no hardware test was performed. The OpenStrap hardware result remains the PR author's report; the existing issue reports retain their own stated firmware and measurement limits. Documentation whitespace checks passed.
