import Foundation

/// #761: READ-ONLY enumeration of the strap's own feature-flag key list.
///
/// NOOP already WRITES feature flags (`SET_FF_VALUE` / 0x78, the R22 deep-stream unlock in
/// `Whoop5Config`) but has never been able to ASK a strap which flags it knows. The protocol has a
/// symmetric read side that NOOP never implemented — `whoop_protocol.json` `CommandNumber` names all of
/// it: 117 `START_FF_KEY_EXCHANGE`, 118 `SEND_NEXT_FF`, 120 `SET_FF_VALUE`, 128 `GET_FF_VALUE` (and the
/// device-config quartet 115/116/119/121). This file decodes the **enumeration** pair only — 117 then
/// repeated 118 — which reads the key NAMES and nothing else.
///
/// `GET_FF_VALUE` (128) is deliberately NOT implemented: the only hands-on report of it
/// (`johnmiddleton12/wearable`, docs/specs/2026-05-24-whoop-protocol-complete.md §4, run against the
/// author's own WHOOP 4.0 on fw 41.16.6.0) states its reply's value field is contaminated by a stale
/// shared buffer, so a read of on/off is unreliable. The same session ran the 117→118 loop and got a
/// complete key dump, which is why the enumerate path is the one built here.
///
/// **Read-only.** The probe writes command frames in order to read — exactly like the Oura feature-status
/// probe NOOP already ships (`Packages/OuraProtocol/…/Commands.swift`, `spo2ReadStatus()` /
/// `realStepsReadStatus()`, `2f 02 20 <feature>`) — but sets no value, and 120/119 (the SET verbs) are
/// never sent from this path. Nothing about strap state changes.
///
/// ## Wire shape
///
/// Request: command 117 or 118 with body `[0x01]` — the same inner b3 convention CLIENT_HELLO and
/// `Whoop5Config`'s SET_CONFIG writes use. 118 carries a **cursor, not an index**: the same body is sent
/// repeatedly and the strap walks its own list.
///
/// Response: an ordinary COMMAND_RESPONSE echoing the command byte. The two-byte response header
/// (`pay[0..2]`, whose second byte is the 5/MG result code) precedes the record, exactly as every other
/// COMMAND_RESPONSE in this codebase decodes it — `GET_BATTERY_LEVEL` reads its value at `pay[2]` on both
/// families (`PostHooks.swift`, `Interpreter.decodeWhoop5CommandResponse`). So the record starts at
/// `pay[2]`:
///
/// ```
/// 117 START_FF_KEY_EXCHANGE   record = [revision u8][numberOfFeatureFlags u16 LE][padding…]
/// 118 SEND_NEXT_FF            record = [revision u8][index u8][validKey u8][key ASCII, NUL-terminated][padding…]
/// ```
///
/// Two independent sources agree on that ordering, which is why it is decoded rather than left raw:
/// the field ORDER and the opcode numbers are documented in a decompiled official client's response
/// types (`StartFeatureFlagKeyExchangeResponsePacket { revision, numberOfFeatureFlags, padding }`,
/// `SendNextFeatureFlagResponsePacket { revision, index, validKey, keyStringId, padding }`), and the
/// hands-on WHOOP 4.0 dump above shows literal replies of `0a 01 | 01 <count u16>` and
/// `0a 01 | 01 <index> 01 <key name…>`, with `0a 01 | 01 ff …` when the cursor is exhausted. Those are
/// facts about bytes on a wire, reimplemented here in NOOP's own code — no client code or naming is
/// copied (see ATTRIBUTION.md, and #822 on the fact/expression line).
///
/// **Unverified on 5/MG.** The hardware result behind this layout is a WHOOP 4.0 with an R19-era key
/// list; whether a 5/MG answers 117 at all is exactly what the probe exists to find out. Everything
/// here therefore fails closed: a frame whose CRCs don't pass, whose type isn't COMMAND_RESPONSE, or
/// whose record is short is REJECTED rather than guessed at, and an implausible flag count is reported
/// but never trusted as a loop bound.
public enum FeatureFlagProbe {

    // MARK: - Wire constants

    /// START_FF_KEY_EXCHANGE (117 / 0x75) — ask the strap how many feature flags it knows. Read-only.
    public static let startKeyExchangeCmd: UInt8 = 117
    /// SEND_NEXT_FF (118 / 0x76) — advance the strap's own cursor and report one key name. Read-only.
    public static let sendNextFlagCmd: UInt8 = 118

    /// Request body for both commands: the inner b3 byte `0x01`, the convention GET_HELLO and the
    /// SET_CONFIG family use. `BLEManager.send` carries it as the first payload byte.
    public static let requestBody: [UInt8] = [0x01]

    /// Hard ceiling on 118 round-trips in one probe, independent of the count the strap reports. A
    /// firmware that answers with a nonsense count (or never advances its cursor) must not be able to
    /// drive an unbounded write loop on the command characteristic. The published 4.0 dump enumerated
    /// 11 flags; 128 leaves generous headroom for a 5/MG's larger R22-era list.
    public static let maxFlags = 128

    /// Longest key name accepted from a reply. The SET side NUL-pads names to 32 bytes
    /// (`Whoop5Config.payloadBody`), so a longer run of printable bytes means we are reading padding or
    /// a mis-anchored record, not a key.
    public static let maxKeyLength = 32

    /// START_DEVICE_CONFIG_KEY_EXCHANGE (115 / 0x73) — the device-config twin of 117. Read-only.
    public static let startDeviceConfigKeyExchangeCmd: UInt8 = 115
    /// SEND_NEXT_DEVICE_CONFIG (116 / 0x74) — the device-config twin of 118. Read-only.
    public static let sendNextDeviceConfigCmd: UInt8 = 116

    /// How many consecutive `validKey = 0` replies the walk steps over before it gives up on the
    /// EMPTY-SLOT reading (see `NextResponse.isEmptySlot`).
    ///
    /// Calibrated on the one 117/118 walk this project has: that strap announced 16 keys and served
    /// indices **1–10 then 13–18** — a two-slot hole it handled itself, without ever sending
    /// `validKey = 0`. A firmware that instead exposes its holes would show them as runs of that size,
    /// so eight is four times the largest hole ever observed and still a hard bound: the empty-slot
    /// experiment can cost at most eight extra round-trips beyond where the walk used to stop.
    public static let maxConsecutiveEmptySlots = 8

    /// Extra `SEND_NEXT` replies the walk takes AFTER the strap's announced count is satisfied, so the
    /// strap — not our arithmetic — gets to end its own list.
    ///
    /// This exists because of what the announced count actually did on hardware: the 117/118 walk stopped
    /// at exactly `steps == count`, having never seen `index = 0xFF` **or** `validKey = 0`. Every entry
    /// came back valid and named. So the list was not observed to end; the client stopped asking. The
    /// same strap served indices up to **18** while announcing **16**, which is the calibration: an
    /// allowance of four is twice that observed excess, and still bounded by `maxFlags`.
    public static let countOvershootAllowance = 4

    /// Ceiling on record bytes rendered as hex in one trace line. Records are short (`revision`, `index`,
    /// `validKey`, a ≤32-byte name, padding), so anything past this is already evidence that the record
    /// is not the documented layout — and the byte COUNT is always reported even when the tail is elided,
    /// so the finding survives the elision.
    public static let maxRawHexBytes = 64

    // MARK: - Namespaces

    /// One enumerate pair — the opcodes the walk drives and the words the report prints for them.
    ///
    /// The protocol's own `CommandNumber` table names two symmetric enumerate pairs (117/118 for feature
    /// flags, 115/116 for device config). Both are walked by the SAME code here, so a fix to the walk's
    /// terminator handling cannot apply to one namespace and miss the other.
    ///
    /// Reusing this decoder for 115/116 ASSUMES the two share a record layout — an inference from the
    /// naming symmetry in that table, not an observation. It fails closed: a mismatch surfaces as
    /// `.truncated` or as a count `countIsPlausible` rejects.
    public struct Namespace: Equatable, Sendable {
        public let startCmd: UInt8
        public let nextCmd: UInt8
        public let startLabel: String
        public let nextLabel: String
        /// Report title, e.g. `FEATURE-FLAG ENUMERATION PROBE`.
        public let title: String
        /// What the namespace is called in prose, e.g. `feature-flag`.
        public let noun: String
        /// What ONE entry is called in prose, e.g. `flag`.
        public let entryNoun: String
        /// Heading for the collected list, e.g. `Flags`.
        public let listHeading: String
        public init(startCmd: UInt8, nextCmd: UInt8, startLabel: String, nextLabel: String,
                    title: String, noun: String, entryNoun: String, listHeading: String) {
            self.startCmd = startCmd
            self.nextCmd = nextCmd
            self.startLabel = startLabel
            self.nextLabel = nextLabel
            self.title = title
            self.noun = noun
            self.entryNoun = entryNoun
            self.listHeading = listHeading
        }
    }

    /// 117/118 — the feature-flag key list.
    public static let featureFlagNamespace = Namespace(
        startCmd: startKeyExchangeCmd, nextCmd: sendNextFlagCmd,
        startLabel: "START_FF_KEY_EXCHANGE", nextLabel: "SEND_NEXT_FF",
        title: "FEATURE-FLAG ENUMERATION PROBE", noun: "feature-flag", entryNoun: "flag",
        listHeading: "Flags")

    /// 115/116 — the device-config key list.
    public static let deviceConfigNamespace = Namespace(
        startCmd: startDeviceConfigKeyExchangeCmd, nextCmd: sendNextDeviceConfigCmd,
        startLabel: "START_DEVICE_CONFIG_KEY_EXCHANGE", nextLabel: "SEND_NEXT_DEVICE_CONFIG",
        title: "DEVICE-CONFIG ENUMERATION PROBE", noun: "device-config", entryNoun: "config key",
        listHeading: "Keys")

    /// Why a walk stopped. A STRING reason reads well in a log and a CODE can be asserted on, and both
    /// are always set together: a truncated walk that reports no reason at all is precisely how a partial
    /// key list gets mistaken for a complete one.
    public enum StopCode: String, Equatable, Sendable {
        /// The strap served `index = 0xFF`. The one terminator this project has ever seen unambiguously.
        case endMarker
        /// A `validKey = 0` reply repeated the previous reply's index: the cursor did not advance, so
        /// this walk cannot reach anything beyond that point. Note what this does NOT establish — a
        /// firmware whose cursor parks on an empty slot emits the identical frame, so "the list ends
        /// here" and "the walk is stuck on a hole" are not separable by this observation.
        case emptySlotCursorParked
        /// `maxConsecutiveEmptySlots` consecutive `validKey = 0` replies, with the index still advancing.
        case emptySlotRunCap
        /// `maxFlags` replies. A client-side bound: says nothing about where the strap's list ends.
        case stepCap
        /// The announced count plus `countOvershootAllowance` was spent. Also a client-side bound.
        case announcedCountOvershoot
        /// The strap answered nothing inside the probe's window.
        case timeout
        /// The strap refused the verb (result `UNSUPPORTED`).
        case unsupported
        /// A reply did not decode. Our limitation, and labelled as ours.
        case parseFailure
    }

    // MARK: - Decoded responses

    /// Why a frame was not decoded. Distinct cases so the probe can say *what* went wrong in the log
    /// instead of silently dropping a reply.
    public enum ParseFailure: String, Error, Equatable, Sendable {
        /// A CRC did not verify. Bad bytes never drive state (BLE safety contract §2).
        case crc
        /// Not a COMMAND_RESPONSE frame, or too short to hold the envelope.
        case envelope
        /// A COMMAND_RESPONSE for a different command.
        case wrongCommand
        /// The record is shorter than the fields it must carry.
        case truncated
    }

    /// Decoded `START_FF_KEY_EXCHANGE` reply.
    public struct StartResponse: Equatable, Sendable {
        /// Result code byte (`pay[1]`). Labelled only on 5/MG, where the codebase has already pinned its
        /// meaning (0 FAILURE / 1 SUCCESS / 2 PENDING / 3 UNSUPPORTED); nil on WHOOP 4.0, where the same
        /// byte's semantics are not established.
        public let resultCode: Int?
        /// Record `revision` — the layout version the firmware answers with.
        public let revision: Int
        /// `numberOfFeatureFlags` read as u16 LE (`record[1] | record[2] << 8`). NOT trusted as a loop
        /// bound on its own, and NOT the only defensible reading of those bytes — see `singleByteCount`.
        public let count: Int
        /// The raw record bytes this response was decoded from, kept so the report can print them.
        /// Parsed fields are a claim about the layout; these bytes are the evidence for it.
        public let record: [UInt8]
        public init(resultCode: Int?, revision: Int, count: Int, record: [UInt8] = []) {
            self.resultCode = resultCode
            self.revision = revision
            self.count = count
            self.record = record
        }
        /// True when the count is inside the range a real key list could plausibly occupy.
        public var countIsPlausible: Bool { count > 0 && count <= FeatureFlagProbe.maxFlags }

        /// The same field read as a SINGLE byte — i.e. on the reading where `record[2]` is padding
        /// rather than the count's high byte.
        ///
        /// The layout this decoder implements calls the field u16 LE. Nothing observed here settles that:
        /// every count seen so far has had `record[2] == 0x00`, where a u16 read and a single-byte read
        /// return the SAME number, so no capture yet distinguishes them. Both are therefore carried, and
        /// the report says plainly when they agree (no evidence either way) and when they differ (which
        /// is itself the finding). Guessing one and discarding the other is how a walk gets bounded by a
        /// number nobody checked.
        public var singleByteCount: Int? { record.count >= 2 ? Int(record[1]) : nil }
        /// The byte a u16 reading treats as the count's high half. `0x00` means the two readings agree.
        public var countHighByte: Int? { record.count >= 3 ? Int(record[2]) : nil }
        /// True when the u16 and single-byte readings return the same number, i.e. this reply is silent
        /// on the field's width.
        public var countReadingsAgree: Bool { countHighByte == 0 }
    }

    /// Decoded `SEND_NEXT_FF` reply.
    public struct NextResponse: Equatable, Sendable {
        public let resultCode: Int?
        public let revision: Int
        /// The cursor position the strap reports for this entry. `0xFF` marks the walk finished.
        public let index: Int
        /// The firmware's own "this entry is a real key" flag.
        public let validKey: Bool
        /// The key name, when one decodes as printable ASCII; nil when the entry carries none.
        public let key: String?
        /// The raw record bytes this response was decoded from, kept so the report can print them.
        public let record: [UInt8]
        public init(resultCode: Int?, revision: Int, index: Int, validKey: Bool, key: String?,
                    record: [UInt8] = []) {
            self.resultCode = resultCode
            self.revision = revision
            self.index = index
            self.validKey = validKey
            self.key = key
            self.record = record
        }

        /// The strap's UNAMBIGUOUS end marker: `index = 0xFF`.
        ///
        /// This used to also mean `validKey = 0`, on the reading that the firmware sets that flag to
        /// signal the end of its list. That reading is not established. The file's own header note says
        /// the record layout is **unverified on 5/MG** — it was derived from a WHOOP 4.0 with an R19-era
        /// key list — and the terminator semantics came with the layout.
        ///
        /// What a 5/MG (WS50_r03) actually served, on the only walks this project has:
        ///
        /// - 117/118: sixteen replies, every one `validKey = 1` with a decodable name, indices 1–10 then
        ///   13–18. The strap handled its own two-slot hole internally. **Neither** `validKey = 0` **nor**
        ///   `index = 0xFF` was ever served — the walk ended because the client stopped asking at the
        ///   announced count.
        /// - 115/116: the final reply carried `index = 255` **and** `validKey = 0` **together**. Both
        ///   conditions fired on the same frame, so that run cannot say which one the firmware meant.
        ///
        /// So on this hardware the disjunction has never been separated. If `validKey = 0` in fact marks
        /// an EMPTY or RETIRED SLOT with the list continuing past it, then stopping there truncates —
        /// the identical failure `isSkippable` exists to prevent, one condition over, and one that would
        /// silently shorten every published key list including this project's own. `isEmptySlot` is that
        /// case, and the walk now steps over it and records what comes next.
        public var isExhausted: Bool { index == 0xFF }

        /// `validKey = 0` WITHOUT the 0xFF end marker — the ambiguous case, and the one this probe exists
        /// to resolve. Recorded, stepped over, and bounded by `maxConsecutiveEmptySlots`; what the strap
        /// serves next is the evidence that separates "end of list" from "empty slot".
        public var isEmptySlot: Bool { !validKey && index != 0xFF }

        /// The firmware calls this a real key but the name did not decode. Record it and KEEP WALKING.
        ///
        /// Safe because the walk was never bounded by this: `maxFlags` caps the replies and the announced
        /// count bounds it further, so skipping can only spend budget that already exists. And it matters
        /// most on the run that matters most — the first real capture is the expensive one to obtain, so
        /// truncating it on our own strictness is the worst possible time to lose entries.
        public var isSkippable: Bool { validKey && index != 0xFF && key == nil }
    }

    // MARK: - Parsing

    /// Decode a `START_FF_KEY_EXCHANGE` COMMAND_RESPONSE. CRC-gated: a frame whose checksums fail is
    /// rejected before any field is read.
    ///
    /// `expecting` defaults to 117 and exists so the DEVICE-CONFIG twin
    /// `START_DEVICE_CONFIG_KEY_EXCHANGE` (115) is decoded by this same code — the reuse contract
    /// documented on `Namespace`.
    public static func parseStart(frame: [UInt8], family: DeviceFamily,
                                  expecting: UInt8 = startKeyExchangeCmd)
        -> Result<StartResponse, ParseFailure> {
        switch record(frame: frame, family: family, expecting: expecting) {
        case .failure(let f): return .failure(f)
        case .success(let r):
            guard r.record.count >= 3 else { return .failure(.truncated) }
            let count = Int(r.record[1]) | (Int(r.record[2]) << 8)
            return .success(StartResponse(resultCode: r.resultCode, revision: Int(r.record[0]),
                                          count: count, record: r.record))
        }
    }

    /// Decode a `SEND_NEXT_FF` COMMAND_RESPONSE. CRC-gated like `parseStart`.
    /// `expecting` defaults to 118 and carries the same reuse contract: 116
    /// (`SEND_NEXT_DEVICE_CONFIG`) walks the device-config namespace through this decoder.
    public static func parseNext(frame: [UInt8], family: DeviceFamily,
                                 expecting: UInt8 = sendNextFlagCmd)
        -> Result<NextResponse, ParseFailure> {
        switch record(frame: frame, family: family, expecting: expecting) {
        case .failure(let f): return .failure(f)
        case .success(let r):
            // revision + index are the minimum: the 0xFF end marker arrives with nothing after it.
            guard r.record.count >= 2 else { return .failure(.truncated) }
            let revision = Int(r.record[0])
            let index = Int(r.record[1])
            let validKey = r.record.count >= 3 ? r.record[2] != 0 : false
            let key = r.record.count >= 4 ? asciiKey(Array(r.record[3...])) : nil
            return .success(NextResponse(resultCode: r.resultCode, revision: revision, index: index,
                                         validKey: validKey, key: key, record: r.record))
        }
    }

    /// The record bytes (everything after the two-byte response header) plus the 5/MG result code.
    private struct Extracted {
        let record: [UInt8]
        let resultCode: Int?
    }

    /// Shared envelope work: verify both CRCs, confirm this is a COMMAND_RESPONSE for `expecting`, and
    /// slice out the record. `cmdOff` is 6 on WHOOP 4.0 (`[type][seq][cmd]` from frame[4]) and 10 on
    /// 5/MG (the puffin envelope inserts the format byte + CRC16 header first); the 4-byte CRC32 trailer
    /// is excluded from the payload on both.
    private static func record(frame: [UInt8], family: DeviceFamily,
                               expecting: UInt8) -> Result<Extracted, ParseFailure> {
        // BLE safety contract §2: CRC-gate everything. A frame that fails either checksum is not data.
        guard verifyFrame(frame, family: family).ok else { return .failure(.crc) }
        let typeOff = family == .whoop5 ? 8 : 4
        let cmdOff = typeOff + 2
        guard frame.count > cmdOff + 4 else { return .failure(.envelope) }
        guard frame[typeOff] == commandResponseType else { return .failure(.envelope) }
        guard frame[cmdOff] == expecting else { return .failure(.wrongCommand) }
        let payStart = cmdOff + 1
        let payEnd = frame.count - 4          // strip the CRC32 trailer
        guard payEnd > payStart else { return .failure(.truncated) }
        let pay = Array(frame[payStart..<payEnd])
        // The record sits behind the 2-byte response header, the same offset every other
        // COMMAND_RESPONSE decoder in this package uses (battery %, clock).
        guard pay.count > responseHeaderBytes else { return .failure(.truncated) }
        let resultCode: Int? = family == .whoop5 ? Int(pay[1]) : nil
        return .success(Extracted(record: Array(pay[responseHeaderBytes...]), resultCode: resultCode))
    }

    /// COMMAND_RESPONSE packet type (`PacketType.COMMAND_RESPONSE` = 36 / 0x24).
    static let commandResponseType: UInt8 = 36

    /// Bytes of response header ahead of the packet record. `pay[1]` is the 5/MG result code.
    static let responseHeaderBytes = 2

    /// Read a NUL-terminated printable-ASCII key name. Returns nil when the first byte is already NUL or
    /// non-printable (no name in this entry) so a padding run can never be reported as a flag.
    static func asciiKey(_ bytes: [UInt8]) -> String? {
        var out: [UInt8] = []
        for b in bytes {
            if b == 0 { break }
            guard (32...126).contains(b) else { return nil }
            out.append(b)
            if out.count > maxKeyLength { return nil }
        }
        return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
    }

    /// Lower-case space-separated hex, for putting the RAW bytes of a reply in the log next to the
    /// fields decoded from them.
    ///
    /// Parsed output alone has repeatedly turned out to be insufficient evidence here: a claim about the
    /// record layout cannot be re-checked, or contradicted, from the fields that layout produced. Over
    /// `maxRawHexBytes` the tail is elided and the true length is printed, so the elision itself is
    /// visible and a suspiciously long record still reads as one.
    public static func hex(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "(empty)" }
        let shown = bytes.prefix(maxRawHexBytes)
        var out = shown.map { String(format: "%02x", $0) }.joined(separator: " ")
        if bytes.count > maxRawHexBytes { out += " … (\(bytes.count) bytes total)" }
        return out
    }

    /// 5/MG result-code label (0 FAILURE / 1 SUCCESS / 2 PENDING / 3 UNSUPPORTED), matching
    /// `BodyLocationProbe`. Unknown codes keep their number rather than being coerced.
    static func resultLabel(_ code: Int) -> String {
        switch code {
        case 0: return "FAILURE"
        case 1: return "SUCCESS"
        case 2: return "PENDING"
        case 3: return "UNSUPPORTED"
        default: return "result\(code)"
        }
    }
}

// MARK: - Report

/// The running result of one enumeration probe, rendered into the copyable text the Devices dialog and
/// the strap log both show. Pure and order-dependent (start → next… → finish), so `swift test` covers
/// the whole report without a strap. Kotlin twin: `FeatureFlagProbeReport` in
/// `android/…/protocol/FeatureFlagProbe.kt`; the rendered text is byte-identical across platforms so a
/// shared strap log reads the same either side.
public struct FeatureFlagProbeReport: Equatable, Sendable {

    /// Which family the probe ran against (labels only).
    public let family: DeviceFamily
    /// Which enumerate pair this walk drives — 117/118 or 115/116. The walk logic is identical; only
    /// the opcodes and the words differ, so neither namespace can drift from the other's terminator rules.
    public let namespace: FeatureFlagProbe.Namespace
    /// Key names collected, in the order the strap reported them.
    public private(set) var keys: [String] = []
    /// Trace lines: one per reply plus any failure notes.
    public private(set) var trace: [String] = []
    /// SEND_NEXT replies seen. Bounds the walk (see `noteNext`).
    public private(set) var steps = 0
    /// The count the strap reported for the START verb, when it answered.
    public private(set) var reportedCount: Int?
    /// The same count read as a single byte (`record[1]`), when the record carried one.
    public private(set) var reportedCountSingleByte: Int?
    /// `record[2]` — the byte a u16 reading treats as the count's high half.
    public private(set) var reportedCountHighByte: Int?
    /// Result code of the START reply on 5/MG (nil on 4.0, or before it lands).
    public private(set) var startResult: Int?
    /// Entries the strap flagged as real keys whose NAME did not decode, and which the walk stepped over
    /// rather than stopping at. Surfaced in the report so a dump with holes never reads as a complete list.
    public private(set) var skipped = 0
    /// Replies carrying `validKey = 0` WITHOUT the 0xFF end marker, which the walk stepped over.
    public private(set) var emptySlots = 0
    /// True once any `validKey = 0` reply arrived without the 0xFF marker.
    public private(set) var sawEmptySlot = false
    /// True once `index = 0xFF` arrived.
    public private(set) var sawEndMarker = false
    /// True when the 0xFF reply ALSO carried `validKey = 0` — i.e. both terminator conditions fired on
    /// one frame, and that run cannot say which one the firmware meant. This is what a 5/MG served on
    /// 115/116, and the reason the two have never been separated.
    public private(set) var endMarkerAlsoCarriedInvalidFlag = false
    /// Replies the strap served AFTER the first `validKey = 0`. Any value above zero is the decisive
    /// observation: the list did not end there.
    public private(set) var repliesAfterFirstEmptySlot = 0
    /// Key names collected after the first `validKey = 0` — keys a walk that stopped there would have lost.
    public private(set) var keysAfterFirstEmptySlot = 0
    /// Replies after the first `validKey = 0` that the FIRMWARE flagged as real entries, whether or not
    /// this parser could decode their names.
    ///
    /// This — not the decoded-key count — is what makes the empty-slot reading decisive. #874's rule
    /// applies to the conclusion as much as to the walk: if the strap named an entry past the hole and our
    /// ASCII filter declined it, the list still continued, and reporting "inconclusive" there would be our
    /// parser's limitation deciding a question about the firmware.
    public private(set) var validEntriesAfterFirstEmptySlot = 0
    /// Replies taken past the strap's announced count, under `countOvershootAllowance`.
    public private(set) var repliesPastAnnouncedCount = 0
    /// Set once the walk stopped for a reason we can name.
    public private(set) var stopReason: String?
    /// The same reason as a code, so a caller (or a test) can branch on it rather than on prose.
    public private(set) var stopCode: FeatureFlagProbe.StopCode?
    /// True once the walk has a reason to stop. The BLE driver consults this after EVERY reply, so a
    /// refusal recorded on the START reply ends the run instead of being stepped over into the next verb.
    public var hasStopped: Bool { stopCode != nil }
    /// The index the previous reply carried, for spotting a cursor that stopped advancing.
    private var lastIndex: Int?
    /// Length of the current unbroken run of `validKey = 0` replies, reset by any valid entry.
    private var consecutiveEmptySlots = 0

    public init(family: DeviceFamily,
                namespace: FeatureFlagProbe.Namespace = FeatureFlagProbe.featureFlagNamespace) {
        self.family = family
        self.namespace = namespace
    }

    /// Record the START reply.
    public mutating func noteStart(_ r: FeatureFlagProbe.StartResponse) {
        reportedCount = r.count
        reportedCountSingleByte = r.singleByteCount
        reportedCountHighByte = r.countHighByte
        startResult = r.resultCode
        var line = "\(namespace.startLabel)(\(namespace.startCmd)) → revision=\(r.revision) count=\(r.count)"
        if let c = r.resultCode { line += " result=\(FeatureFlagProbe.resultLabel(c))(\(c))" }
        line += " raw=\(FeatureFlagProbe.hex(r.record))"
        if !r.countIsPlausible {
            line += "  ⚠︎ count outside 1…\(FeatureFlagProbe.maxFlags) — treated as unknown, the walk still stops on the strap's own end marker"
        }
        trace.append(line)
        if let c = r.resultCode, c == 3 {
            stopReason = "strap refused \(namespace.startLabel)(\(namespace.startCmd)) with UNSUPPORTED(3)"
            stopCode = .unsupported
        }
    }

    /// Record one SEND_NEXT reply. Returns true when the walk should continue.
    ///
    /// The decision order IS the experiment. `index = 0xFF` ends the walk, because that marker is the one
    /// thing a strap has served here unambiguously. `validKey = 0` on its own does NOT end it: the walk
    /// steps over the entry, sends the next-record verb again, and records what comes back — which is the
    /// only way to tell "end of list" from "empty slot" apart. Everything past that point is a
    /// CLIENT-side bound (`maxConsecutiveEmptySlots`, `maxFlags`, the announced count plus its
    /// overshoot), and each one names itself in `stopCode` so a walk that ended on our arithmetic can
    /// never be read as a walk the strap ended.
    @discardableResult
    public mutating func noteNext(_ r: FeatureFlagProbe.NextResponse) -> Bool {
        steps += 1
        if sawEmptySlot { repliesAfterFirstEmptySlot += 1 }
        var line = "\(namespace.nextLabel)(\(namespace.nextCmd)) → index=\(r.index) validKey=\(r.validKey)"
        if let k = r.key { line += " key=\"\(k)\"" }
        if let c = r.resultCode { line += " result=\(FeatureFlagProbe.resultLabel(c))(\(c))" }
        line += " raw=\(FeatureFlagProbe.hex(r.record))"
        trace.append(line)

        // 0. An explicit refusal. UNSUPPORTED(3) says the firmware does not serve this verb, so nothing
        // in the record is meaningful and there is nothing to walk. Checked FIRST, before any field is
        // acted on, and named as the strap's answer rather than as one of our bounds.
        if let c = r.resultCode, c == 3 {
            stopReason = "strap refused \(namespace.nextLabel)(\(namespace.nextCmd)) with UNSUPPORTED(3)"
            stopCode = .unsupported
            return false
        }

        // 1. The strap's own unambiguous end marker. Nothing overrides this.
        if r.isExhausted {
            sawEndMarker = true
            if !r.validKey {
                endMarkerAlsoCarriedInvalidFlag = true
                trace[trace.count - 1] += "  (index=0xFF AND validKey=0 on the same reply — both terminator conditions at once)"
            }
            stopReason = "cursor exhausted (index 0xFF)"
            stopCode = .endMarker
            return false
        }

        // 2. `validKey = 0` with no end marker: the ambiguous case. Step over it and keep asking.
        if r.isEmptySlot {
            let parked = (lastIndex == r.index)
            lastIndex = r.index
            emptySlots += 1
            consecutiveEmptySlots += 1
            let runLength = consecutiveEmptySlots
            sawEmptySlot = true
            trace[trace.count - 1] += "  (validKey=0 without the 0xFF marker — treated as an EMPTY SLOT, walk continues)"
            if parked {
                // The cursor did not move. A firmware that means "end of list" parks there and repeats
                // itself, so this is the observation that settles the ambiguity the other way — and it
                // costs two round-trips rather than a full cap's worth.
                stopReason = "validKey=0 repeated at index \(r.index) without advancing — the cursor is "
                    + "parked, so on this firmware validKey=0 IS a terminator"
                stopCode = .emptySlotCursorParked
                return false
            }
            if runLength >= FeatureFlagProbe.maxConsecutiveEmptySlots {
                stopReason = "\(runLength) consecutive validKey=0 replies (cap "
                    + "\(FeatureFlagProbe.maxConsecutiveEmptySlots)) — a CLIENT-side bound, not the strap's"
                stopCode = .emptySlotRunCap
                return false
            }
        } else {
            lastIndex = r.index
            consecutiveEmptySlots = 0
            if sawEmptySlot { validEntriesAfterFirstEmptySlot += 1 }
            if r.isSkippable {
                // Our decode declined the name; the strap still says the entry is real and may have more
                // after it. Count it so a partial dump describes itself instead of looking complete.
                skipped += 1
                trace[trace.count - 1] += "  (name did not decode — skipped, walk continues)"
            }
            if let k = r.key, !keys.contains(k) {
                keys.append(k)
                if sawEmptySlot { keysAfterFirstEmptySlot += 1 }
            }
        }

        // 3. Bound the walk on REPLIES, not on distinct keys: a firmware whose cursor never advances would
        // repeat one name forever, and a key-count bound would never stop writing the verb to the strap.
        if steps >= FeatureFlagProbe.maxFlags {
            stopReason = "safety cap of \(FeatureFlagProbe.maxFlags) replies reached"
            stopCode = .stepCap
            return false
        }
        // 4. The announced count, PLUS an overshoot, so the strap gets to end its own list. On the one
        // 117/118 walk this project has, `steps >= count` was the only thing that stopped it — no marker,
        // no validKey=0 — which means that list was never observed to end at all.
        if let count = reportedCount, count > 0, count <= FeatureFlagProbe.maxFlags {
            if steps > count { repliesPastAnnouncedCount = steps - count }
            if steps >= count + FeatureFlagProbe.countOvershootAllowance {
                stopReason = "walked the \(count) entries the strap announced plus "
                    + "\(FeatureFlagProbe.countOvershootAllowance) more — a CLIENT-side bound; the strap "
                    + "never sent an end marker, so the list is not known to end here"
                stopCode = .announcedCountOvershoot
                return false
            }
        }
        return true
    }

    /// Record a reply that could not be decoded. `frame`, when supplied, is logged in full: a frame that
    /// failed its CRC is still the only evidence of what the strap actually put on the wire.
    public mutating func noteFailure(_ f: FeatureFlagProbe.ParseFailure, command: Int,
                                     frame: [UInt8] = []) {
        let why: String
        switch f {
        case .crc:          why = "CRC failed — frame rejected (never decoded)"
        case .envelope:     why = "not a COMMAND_RESPONSE envelope"
        case .wrongCommand: why = "COMMAND_RESPONSE for a different command"
        case .truncated:    why = "record too short for the documented layout"
        }
        var line = "cmd \(command) reply not decoded: \(why)"
        if !frame.isEmpty { line += " raw frame=\(FeatureFlagProbe.hex(frame))" }
        trace.append(line)
        if stopReason == nil {
            stopReason = why
            stopCode = .parseFailure
        }
    }

    /// Record the strap answering nothing at all within the probe's window.
    public mutating func noteTimeout(command: Int, seconds: Int) {
        trace.append("no COMMAND_RESPONSE for opcode \(command) within \(seconds)s")
        if stopReason == nil {
            stopReason = "strap served no reply to opcode \(command) within \(seconds)s"
            stopCode = .timeout
        }
    }

    // MARK: - Findings

    /// What this run established about the two terminator conditions — the question the probe exists to
    /// answer, stated in the report rather than left for a reader to reconstruct from the trace.
    public var terminatorFinding: String {
        if sawEmptySlot && (validEntriesAfterFirstEmptySlot > 0 || sawEndMarker) {
            var s = "DECISIVE — validKey=0 is an EMPTY/RETIRED SLOT on this firmware, not the end of the "
            s += "list: the strap served \(repliesAfterFirstEmptySlot) further repl(ies) after the first "
            s += "validKey=0"
            if validEntriesAfterFirstEmptySlot > 0 {
                s += ", \(validEntriesAfterFirstEmptySlot) of them flagged validKey=1"
            }
            if keysAfterFirstEmptySlot > 0 { s += ", naming \(keysAfterFirstEmptySlot) more key(s)" }
            if sawEndMarker { s += ", and ended on the index=0xFF marker" }
            s += ". A walk that stopped on validKey=0 would have been truncated here."
            return s
        }
        if stopCode == .emptySlotCursorParked {
            // The DECISIVE label is kept, narrowed to what the run actually decides. "There is nothing
            // past it" is a step beyond the observation, and TWO firmwares emit this identical frame:
            // a list that genuinely ends at a parked sentinel, and a cursor that advances only on a valid
            // record — where validKey=0 is a SLOT, the walk is stuck on a hole, and keys may sit behind
            // it. The second is precisely the reading this probe exists to make testable, so printing the
            // first as decided would hand a reader the conclusion the probe was written to question.
            return "DECISIVE — validKey=0 is a TERMINATOR on this firmware: the next request returned the "
                + "same index with validKey=0 again, so the cursor does not advance past it, so this walk "
                + "cannot see anything beyond. Whether the list truly ends here is not separable from a "
                + "firmware whose cursor parks on an empty slot."
        }
        if sawEmptySlot {
            return "INCONCLUSIVE — validKey=0 was served and the walk continued past it, but a client-side "
                + "bound ended the run before the strap did. Nothing here separates 'end of list' from "
                + "'empty slot'."
        }
        if sawEndMarker && endMarkerAlsoCarriedInvalidFlag {
            return "AMBIGUOUS — the walk ended on a reply carrying index=0xFF AND validKey=0 together, so "
                + "both terminator conditions fired at once and this run cannot say which one the firmware "
                + "meant."
        }
        if sawEndMarker {
            return "index=0xFF ended the walk with validKey still true on the same reply, so the 0xFF "
                + "marker alone terminates. validKey=0 was never served, so it is untested here."
        }
        return "NO TERMINATOR OBSERVED — neither validKey=0 nor index=0xFF was served in \(steps) "
            + "repl(ies); the walk ended on a CLIENT-side bound, so the strap's list is not known to end "
            + "where this report stops."
    }

    /// What the announced count actually says, including the reading it does not settle.
    public var countFinding: String? {
        guard let count = reportedCount else { return nil }
        var s = "u16 LE read = \(count)"
        if let single = reportedCountSingleByte, let high = reportedCountHighByte {
            s += "; single-byte read = \(single) (high byte "
                + String(format: "0x%02x", high) + ")"
            s += high == 0
                ? " — the two readings AGREE, so this reply does not establish the field's width"
                : " — the two readings DISAGREE; the walk uses the u16 value and plausibility-checks it"
        }
        s += ". Keys yielded: \(keys.count)"
        if skipped > 0 { s += " (+\(skipped) undecodable)" }
        if emptySlots > 0 { s += " (+\(emptySlots) empty slot(s))" }
        let accounted = keys.count + skipped + emptySlots
        if accounted != count {
            s += " — MISMATCH against the announced \(count)"
        }
        if repliesPastAnnouncedCount > 0 {
            s += ". The strap kept answering \(repliesPastAnnouncedCount) repl(ies) past its own announced "
                + "count."
        }
        return s
    }

    /// The full copyable report.
    public func render() -> String {
        let fam = family == .whoop5 ? "WHOOP 5/MG" : "WHOOP 4.0"
        var sb = "#761 \(namespace.title) — \(fam)\n"
        sb += "Read-only: \(namespace.startLabel)(\(namespace.startCmd)) + "
        sb += "\(namespace.nextLabel)(\(namespace.nextCmd)). No value is written; "
        sb += "SET_FF_VALUE(120) and SET_DEVICE_CONFIG_VALUE(119) are never sent from this path.\n"
        sb += "\nVerdict: \(verdict)\n"
        if let stopReason { sb += "Stopped: \(stopReason)\n" }
        if let stopCode { sb += "Stop code: \(stopCode.rawValue)\n" }
        sb += "Terminator: \(terminatorFinding)\n"
        if let countFinding { sb += "Announced count: \(countFinding)\n" }
        sb += "\n\(namespace.listHeading) reported by the strap (\(keys.count)"
        if let reportedCount { sb += " of \(reportedCount) announced" }
        if skipped > 0 { sb += ", \(skipped) name(s) did not decode and were skipped" }
        if emptySlots > 0 { sb += ", \(emptySlots) validKey=0 slot(s) stepped over" }
        sb += "):\n"
        if keys.isEmpty {
            sb += "  (none)\n"
        } else {
            for (i, k) in keys.enumerated() { sb += String(format: "  %2d. ", i + 1) + k + "\n" }
        }
        sb += "\nExchange:\n"
        for line in trace { sb += "  " + line + "\n" }
        return sb
    }

    /// The announced count as a phrase for the verdict line, qualified when it falls outside the range a
    /// real key list could occupy. `noteStart` already marks an implausible count in the trace, but the
    /// verdict is the line that gets pasted into an issue, and restating a number the probe itself
    /// distrusts as bare fact is the same over-claim in a smaller place. A plausible count renders
    /// exactly as before, so the common report is unchanged.
    ///
    /// The noun comes from `namespace`, not a literal: #913 wrote this when the probe walked 117/118 only,
    /// so "flag(s)" was the only possibility. This PR walks 115/116 through the same code, where the
    /// entries are config keys — a hardcoded "flag(s)" would mislabel every device-config report.
    private var announcedFlags: String {
        let n = reportedCount ?? 0
        let plausible = n > 0 && n <= FeatureFlagProbe.maxFlags
        return plausible ? "\(n) \(namespace.entryNoun)(s)" : "an implausible \(n) \(namespace.entryNoun)(s)"
    }

    /// One-line summary of what the probe established.
    public var verdict: String {
        if let startResult, startResult == 3 {
            return "opcode \(namespace.startCmd) REJECTED by firmware (UNSUPPORTED) — this strap does not serve the enumerate verb"
        }
        if keys.isEmpty && reportedCount == nil {
            return "no usable reply — the enumerate path is unconfirmed on this firmware"
        }
        // "named none" would blame the strap for OUR decode. If entries were skipped the strap did name
        // them and this parser rejected the names, which is the opposite conclusion and the one a reader
        // would carry into #103. Same class as `isSkippable`: never report our limitation as the strap's
        // behaviour.
        if keys.isEmpty && skipped > 0 {
            return "strap named \(skipped) \(namespace.entryNoun)(s), none of which decoded as printable ASCII within "
                + "\(FeatureFlagProbe.maxKeyLength) chars — this is our parser rejecting them, NOT the "
                + "strap serving blanks; see the trace for the raw replies"
        }
        // Same discipline one condition over: with no 118 reply decoded, the walk never asked for a
        // single name, so "named none" would blame the strap for OUR timeout (or our parse failure).
        // `steps` counts decoded SEND_NEXT replies, so `steps == 0` is exactly "the key list was never
        // read" — the reachable case being `probeFeatureFlags()` getting its 117 answer and then the 8s
        // timer firing on the first 118. What the strap would have named is unknown, and the report has
        // to say unknown. `stopReason`, rendered directly under this line, names which of the two it was.
        if keys.isEmpty && steps == 0 {
            // Namespace-aware for the same reason as `announcedFlags`: #913 could name SEND_NEXT_FF(118)
            // literally because 117/118 was the only walk; a 115/116 run must say SEND_NEXT_DEVICE_CONFIG(116).
            return "strap announced \(announcedFlags); no \(namespace.nextLabel)(\(namespace.nextCmd)) "
                + "reply was decoded — the key list was never read (inconclusive)"
        }
        if keys.isEmpty {
            // Both halves survive the merge with #913: its doubt about an implausible announced count
            // (`announcedFlags`), and this PR's namespace-aware noun. Taking either side alone would drop
            // the other — #913's version hardcodes "flag(s)" and would mislabel a device-config walk.
            return "strap announced \(announcedFlags) but named none"
        }
        var s = "enumerated \(keys.count) \(namespace.noun) key name(s)"
        if skipped > 0 { s += "; \(skipped) further name(s) did not decode" }
        // A walk that ended on OUR bound is not a complete list, and the one-line summary is the line that
        // gets pasted into an issue. Say it here, not only four lines further down.
        if stopCode == .stepCap || stopCode == .announcedCountOvershoot || stopCode == .emptySlotRunCap {
            s += " — INCOMPLETE: the walk ended on a client-side bound, not on the strap's own end marker"
        }
        return s
    }
}
