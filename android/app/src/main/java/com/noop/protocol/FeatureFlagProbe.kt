package com.noop.protocol

/**
 * #761: READ-ONLY enumeration of the strap's own feature-flag key list. Kotlin twin of Swift
 * `FeatureFlagProbe` / `FeatureFlagProbeReport` (`Packages/WhoopProtocol/…/FeatureFlagProbe.swift`);
 * the decoded fields and the rendered report text are byte-identical across platforms, so a strap log
 * reads the same either side.
 *
 * NOOP already WRITES feature flags (`SET_FF_VALUE` / 0x78, the R22 unlock in [Whoop5Config]) but has
 * never been able to ASK a strap which flags it knows. The protocol's own `CommandNumber` table names
 * the read side — 117 `START_FF_KEY_EXCHANGE`, 118 `SEND_NEXT_FF` — and only the SET pair was ever
 * implemented. This decodes the ENUMERATION pair only: names, no values.
 *
 * `GET_FF_VALUE` (128) is deliberately NOT implemented: the only hands-on report of it
 * (`johnmiddleton12/wearable`, docs/specs/2026-05-24-whoop-protocol-complete.md §4, run against the
 * author's own WHOOP 4.0 on fw 41.16.6.0) states its reply's value field is contaminated by a stale
 * shared buffer, so a read of on/off is unreliable. The same session ran the 117→118 loop and got a
 * complete key dump, which is why the enumerate path is the one built here.
 *
 * **Read-only.** The probe writes command frames in order to read — like the Oura feature-status probe
 * NOOP already ships — but sets no value; 120/119 are never sent from this path.
 *
 * Wire shape. Request: 117 or 118 with body `[0x01]` (the inner b3 convention CLIENT_HELLO and the
 * SET_CONFIG writes use); 118's body is a CURSOR, not an index, so the same frame is repeated to walk
 * the list. Response: an ordinary COMMAND_RESPONSE echoing the command byte, whose record sits behind
 * the 2-byte response header (`pay[1]` is the 5/MG result code) — the same offset every other
 * COMMAND_RESPONSE decoder here uses for its value:
 *
 * ```
 * 117  record = [revision u8][numberOfFeatureFlags u16 LE][padding…]
 * 118  record = [revision u8][index u8][validKey u8][key ASCII, NUL-terminated][padding…]
 * ```
 *
 * Two independent sources agree on that ordering: a decompiled official client's response types
 * (`{revision, numberOfFeatureFlags, padding}` and `{revision, index, validKey, keyStringId, padding}`)
 * and the hands-on WHOOP 4.0 dump above, whose literal replies are `0a 01 | 01 <count u16>` and
 * `0a 01 | 01 <index> 01 <key name…>`, with `0a 01 | 01 ff …` once the cursor is exhausted. Facts about
 * bytes on a wire, reimplemented in NOOP's own code — no client code or naming is copied
 * (see ATTRIBUTION.md).
 *
 * UNVERIFIED on 5/MG: the hardware behind this layout is a WHOOP 4.0 with an R19-era key list. So
 * everything fails closed — a frame whose CRCs fail, whose type is not COMMAND_RESPONSE, or whose
 * record is short is REJECTED rather than guessed at.
 */
object FeatureFlagProbe {

    /** START_FF_KEY_EXCHANGE (117 / 0x75) — how many feature flags the firmware knows. Read-only. */
    const val START_KEY_EXCHANGE_CMD = 117

    /** SEND_NEXT_FF (118 / 0x76) — advance the strap's own cursor, report one key name. Read-only. */
    const val SEND_NEXT_FLAG_CMD = 118

    /** Request body for both: the inner b3 byte `0x01`, as GET_HELLO and the SET_CONFIG family use. */
    val REQUEST_BODY = byteArrayOf(0x01)

    /**
     * Hard ceiling on 118 round-trips in one probe, independent of the count the strap reports. A
     * firmware that answers with a nonsense count (or never advances its cursor) must not be able to
     * drive an unbounded write loop on the command characteristic.
     */
    const val MAX_FLAGS = 128

    /** Longest key name accepted from a reply (the SET side NUL-pads names to 32 bytes). */
    const val MAX_KEY_LENGTH = 32

    /** START_DEVICE_CONFIG_KEY_EXCHANGE (115 / 0x73) — the device-config twin of 117. Read-only. */
    const val START_DEVICE_CONFIG_KEY_EXCHANGE_CMD = 115

    /** SEND_NEXT_DEVICE_CONFIG (116 / 0x74) — the device-config twin of 118. Read-only. */
    const val SEND_NEXT_DEVICE_CONFIG_CMD = 116

    /**
     * How many consecutive `validKey = 0` replies the walk steps over before it gives up on the
     * EMPTY-SLOT reading (see [NextResponse.isEmptySlot]).
     *
     * Calibrated on the one 117/118 walk this project has: that strap announced 16 keys and served
     * indices **1–10 then 13–18** — a two-slot hole it handled itself, without ever sending
     * `validKey = 0`. A firmware that instead exposes its holes would show them as runs of that size, so
     * eight is four times the largest hole ever observed and still a hard bound.
     */
    const val MAX_CONSECUTIVE_EMPTY_SLOTS = 8

    /**
     * Extra SEND_NEXT replies the walk takes AFTER the strap's announced count is satisfied, so the
     * strap — not our arithmetic — gets to end its own list. The 117/118 walk stopped at exactly
     * `steps == count`, having seen neither `index = 0xFF` nor `validKey = 0`; the same strap served
     * indices up to 18 while announcing 16, and four is twice that observed excess.
     */
    const val COUNT_OVERSHOOT_ALLOWANCE = 4

    /**
     * Ceiling on record bytes rendered as hex in one trace line. The byte COUNT is printed even when the
     * tail is elided, so a suspiciously long record still reads as one.
     */
    const val MAX_RAW_HEX_BYTES = 64

    /**
     * One enumerate pair — the opcodes the walk drives and the words the report prints for them.
     *
     * The protocol's own `CommandNumber` table names two symmetric enumerate pairs (117/118 for feature
     * flags, 115/116 for device config). Both are walked by the SAME code here, so a fix to the walk's
     * terminator handling cannot apply to one namespace and miss the other. Reusing this decoder for
     * 115/116 ASSUMES the two share a record layout — an inference from that table's naming symmetry,
     * not an observation. It fails closed.
     */
    data class Namespace(
        val startCmd: Int,
        val nextCmd: Int,
        val startLabel: String,
        val nextLabel: String,
        /** Report title, e.g. `FEATURE-FLAG ENUMERATION PROBE`. */
        val title: String,
        /** What the namespace is called in prose, e.g. `feature-flag`. */
        val noun: String,
        /** What ONE entry is called in prose, e.g. `flag`. */
        val entryNoun: String,
        /** Heading for the collected list, e.g. `Flags`. */
        val listHeading: String,
    )

    /** 117/118 — the feature-flag key list. */
    val FEATURE_FLAG_NAMESPACE = Namespace(
        startCmd = START_KEY_EXCHANGE_CMD, nextCmd = SEND_NEXT_FLAG_CMD,
        startLabel = "START_FF_KEY_EXCHANGE", nextLabel = "SEND_NEXT_FF",
        title = "FEATURE-FLAG ENUMERATION PROBE", noun = "feature-flag", entryNoun = "flag",
        listHeading = "Flags",
    )

    /** 115/116 — the device-config key list. */
    val DEVICE_CONFIG_NAMESPACE = Namespace(
        startCmd = START_DEVICE_CONFIG_KEY_EXCHANGE_CMD, nextCmd = SEND_NEXT_DEVICE_CONFIG_CMD,
        startLabel = "START_DEVICE_CONFIG_KEY_EXCHANGE", nextLabel = "SEND_NEXT_DEVICE_CONFIG",
        title = "DEVICE-CONFIG ENUMERATION PROBE", noun = "device-config", entryNoun = "config key",
        listHeading = "Keys",
    )

    /**
     * Why a walk stopped. A STRING reason reads well in a log and a CODE can be asserted on, and both are
     * always set together: a truncated walk that reports no reason at all is precisely how a partial key
     * list gets mistaken for a complete one. [code] matches the Swift `StopCode` raw values exactly.
     */
    enum class StopCode(val code: String) {
        /** The strap served `index = 0xFF`. The one terminator this project has seen unambiguously. */
        END_MARKER("endMarker"),

        /**
         * A `validKey = 0` reply repeated the previous reply's index: the cursor did not advance, so
         * this walk cannot reach anything beyond that point. Note what this does NOT establish — a
         * firmware whose cursor parks on an empty slot emits the identical frame, so "the list ends
         * here" and "the walk is stuck on a hole" are not separable by this observation.
         */
        EMPTY_SLOT_CURSOR_PARKED("emptySlotCursorParked"),

        /** [MAX_CONSECUTIVE_EMPTY_SLOTS] consecutive `validKey = 0` replies, index still advancing. */
        EMPTY_SLOT_RUN_CAP("emptySlotRunCap"),

        /** [MAX_FLAGS] replies. A client-side bound: says nothing about where the strap's list ends. */
        STEP_CAP("stepCap"),

        /** The announced count plus [COUNT_OVERSHOOT_ALLOWANCE] was spent. Also a client-side bound. */
        ANNOUNCED_COUNT_OVERSHOOT("announcedCountOvershoot"),

        /** The strap answered nothing inside the probe's window. */
        TIMEOUT("timeout"),

        /** The strap refused the verb (result `UNSUPPORTED`). */
        UNSUPPORTED("unsupported"),

        /** A reply did not decode. Our limitation, and labelled as ours. */
        PARSE_FAILURE("parseFailure"),
    }

    /** COMMAND_RESPONSE packet type (36 / 0x24). */
    private const val COMMAND_RESPONSE_TYPE = 36

    /** Bytes of response header ahead of the packet record. `pay[1]` is the 5/MG result code. */
    private const val RESPONSE_HEADER_BYTES = 2

    /** Why a frame was not decoded. Named cases so the probe can say what went wrong. */
    enum class ParseFailure { CRC, ENVELOPE, WRONG_COMMAND, TRUNCATED }

    /** Decoded `START_FF_KEY_EXCHANGE` reply. */
    data class StartResponse(
        val resultCode: Int?,
        val revision: Int,
        /**
         * `numberOfFeatureFlags` read as u16 LE (`record[1] | record[2] shl 8`). NOT trusted as a loop
         * bound on its own, and NOT the only defensible reading of those bytes — see [singleByteCount].
         */
        val count: Int,
        /**
         * The raw record bytes this response was decoded from, kept so the report can print them.
         * Parsed fields are a claim about the layout; these bytes are the evidence for it.
         */
        val record: List<Byte> = emptyList(),
    ) {
        /** True when the count is inside the range a real key list could plausibly occupy. */
        val countIsPlausible: Boolean get() = count > 0 && count <= MAX_FLAGS

        /**
         * The same field read as a SINGLE byte — i.e. on the reading where `record[2]` is padding rather
         * than the count's high byte.
         *
         * The layout this decoder implements calls the field u16 LE. Nothing observed here settles that:
         * every count seen so far has had `record[2] == 0x00`, where a u16 read and a single-byte read
         * return the SAME number. Both are therefore carried, and the report says plainly when they
         * agree (no evidence either way) and when they differ (which is itself the finding).
         */
        val singleByteCount: Int? get() = if (record.size >= 2) record[1].toInt() and 0xFF else null

        /** `record[2]` — the byte a u16 reading treats as the count's high half. */
        val countHighByte: Int? get() = if (record.size >= 3) record[2].toInt() and 0xFF else null

        /** True when the two readings return the same number, i.e. this reply is silent on the width. */
        val countReadingsAgree: Boolean get() = countHighByte == 0
    }

    /** Decoded `SEND_NEXT_FF` reply. */
    data class NextResponse(
        val resultCode: Int?,
        val revision: Int,
        /** Cursor position the strap reports for this entry; `0xFF` marks the walk finished. */
        val index: Int,
        val validKey: Boolean,
        val key: String?,
        /** The raw record bytes this response was decoded from, kept so the report can print them. */
        val record: List<Byte> = emptyList(),
    ) {
        /**
         * The strap's UNAMBIGUOUS end marker: `index = 0xFF`.
         *
         * This used to also mean `validKey = 0`, on the reading that the firmware sets that flag to
         * signal the end of its list. That reading is not established. This file's own header note says
         * the record layout is UNVERIFIED on 5/MG — it was derived from a WHOOP 4.0 with an R19-era key
         * list — and the terminator semantics came with the layout.
         *
         * What a 5/MG (WS50_r03) actually served, on the only walks this project has:
         *
         * - 117/118: sixteen replies, every one `validKey = 1` with a decodable name, indices 1–10 then
         *   13–18. The strap handled its own two-slot hole internally. Neither `validKey = 0` nor
         *   `index = 0xFF` was ever served — the walk ended because the client stopped asking at the
         *   announced count.
         * - 115/116: the final reply carried `index = 255` AND `validKey = 0` together. Both conditions
         *   fired on the same frame, so that run cannot say which one the firmware meant.
         *
         * So on this hardware the disjunction has never been separated. If `validKey = 0` in fact marks
         * an EMPTY or RETIRED SLOT with the list continuing past it, then stopping there truncates — the
         * identical failure [isSkippable] exists to prevent, one condition over. [isEmptySlot] is that
         * case, and the walk now steps over it and records what comes next.
         */
        val isExhausted: Boolean get() = index == 0xFF

        /**
         * `validKey = 0` WITHOUT the 0xFF end marker — the ambiguous case, and the one this probe exists
         * to resolve. Recorded, stepped over, and bounded by [MAX_CONSECUTIVE_EMPTY_SLOTS]; what the
         * strap serves next is the evidence that separates "end of list" from "empty slot".
         */
        val isEmptySlot: Boolean get() = !validKey && index != 0xFF

        /**
         * The firmware calls this a real key but the name did not decode. Record it and KEEP WALKING.
         *
         * Safe because the walk was never bounded by this: [MAX_FLAGS] caps the replies and the announced
         * count bounds it further, so skipping can only spend budget that already exists. And it matters
         * most on the run that matters most — the first real capture is the expensive one to obtain, so
         * truncating it on our own strictness is the worst possible time to lose entries.
         */
        val isSkippable: Boolean get() = validKey && index != 0xFF && key == null
    }

    /** One decode outcome: exactly one of [value] / [failure] is non-null. */
    data class Parsed<T>(val value: T?, val failure: ParseFailure?)

    /**
     * Decode a `START_FF_KEY_EXCHANGE` COMMAND_RESPONSE. CRC-gated.
     *
     * [expecting] defaults to 117 and exists so the DEVICE-CONFIG twin
     * `START_DEVICE_CONFIG_KEY_EXCHANGE` (115) is decoded by this same code — the reuse contract
     * documented on [Namespace].
     */
    fun parseStart(
        frame: ByteArray,
        family: DeviceFamily,
        expecting: Int = START_KEY_EXCHANGE_CMD,
    ): Parsed<StartResponse> {
        val e = extract(frame, family, expecting)
        e.failure?.let { return Parsed(null, it) }
        val r = e.value!!
        if (r.record.size < 3) return Parsed(null, ParseFailure.TRUNCATED)
        val count = (r.record[1].toInt() and 0xFF) or ((r.record[2].toInt() and 0xFF) shl 8)
        return Parsed(
            StartResponse(r.resultCode, r.record[0].toInt() and 0xFF, count, r.record.toList()),
            null,
        )
    }

    /**
     * Decode a `SEND_NEXT_FF` COMMAND_RESPONSE. CRC-gated like [parseStart]. [expecting] defaults to 118
     * and carries the same reuse contract: 116 (`SEND_NEXT_DEVICE_CONFIG`) walks the device-config
     * namespace through this decoder.
     */
    fun parseNext(
        frame: ByteArray,
        family: DeviceFamily,
        expecting: Int = SEND_NEXT_FLAG_CMD,
    ): Parsed<NextResponse> {
        val e = extract(frame, family, expecting)
        e.failure?.let { return Parsed(null, it) }
        val r = e.value!!
        // revision + index are the minimum: the 0xFF end marker arrives with nothing after it.
        if (r.record.size < 2) return Parsed(null, ParseFailure.TRUNCATED)
        val revision = r.record[0].toInt() and 0xFF
        val index = r.record[1].toInt() and 0xFF
        val validKey = if (r.record.size >= 3) r.record[2].toInt() != 0 else false
        val key = if (r.record.size >= 4) asciiKey(r.record.copyOfRange(3, r.record.size)) else null
        return Parsed(NextResponse(r.resultCode, revision, index, validKey, key, r.record.toList()), null)
    }

    private class Extracted(val record: ByteArray, val resultCode: Int?)

    /**
     * Shared envelope work: verify both CRCs, confirm this is a COMMAND_RESPONSE for [expecting], and
     * slice out the record. The command byte is at 6 on WHOOP 4.0 and 10 on 5/MG (the puffin envelope
     * inserts the format byte + CRC16 header); the 4-byte CRC32 trailer is excluded on both.
     */
    private fun extract(frame: ByteArray, family: DeviceFamily, expecting: Int): Parsed<Extracted> {
        // BLE safety contract: CRC-gate everything. A frame that fails either checksum is not data.
        if (!Framing.frameCrcOk(frame, family)) return Parsed(null, ParseFailure.CRC)
        val typeOff = if (family == DeviceFamily.WHOOP5) 8 else 4
        val cmdOff = typeOff + 2
        if (frame.size <= cmdOff + 4) return Parsed(null, ParseFailure.ENVELOPE)
        if ((frame[typeOff].toInt() and 0xFF) != COMMAND_RESPONSE_TYPE) return Parsed(null, ParseFailure.ENVELOPE)
        if ((frame[cmdOff].toInt() and 0xFF) != expecting) return Parsed(null, ParseFailure.WRONG_COMMAND)
        val payStart = cmdOff + 1
        val payEnd = frame.size - 4       // strip the CRC32 trailer
        if (payEnd <= payStart) return Parsed(null, ParseFailure.TRUNCATED)
        val pay = frame.copyOfRange(payStart, payEnd)
        if (pay.size <= RESPONSE_HEADER_BYTES) return Parsed(null, ParseFailure.TRUNCATED)
        val resultCode = if (family == DeviceFamily.WHOOP5) pay[1].toInt() and 0xFF else null
        return Parsed(Extracted(pay.copyOfRange(RESPONSE_HEADER_BYTES, pay.size), resultCode), null)
    }

    /**
     * Read a NUL-terminated printable-ASCII key name. Returns null when the first byte is already NUL
     * or non-printable, so a padding run can never be reported as a flag.
     */
    fun asciiKey(bytes: ByteArray): String? {
        val out = StringBuilder()
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            if (v == 0) break
            if (v < 32 || v > 126) return null
            out.append(v.toChar())
            if (out.length > MAX_KEY_LENGTH) return null
        }
        return if (out.isEmpty()) null else out.toString()
    }

    /**
     * Lower-case space-separated hex, for putting the RAW bytes of a reply in the log next to the fields
     * decoded from them.
     *
     * Parsed output alone has repeatedly turned out to be insufficient evidence here: a claim about the
     * record layout cannot be re-checked, or contradicted, from the fields that layout produced. Over
     * [MAX_RAW_HEX_BYTES] the tail is elided and the true length is printed, so the elision itself is
     * visible and a suspiciously long record still reads as one.
     */
    fun hex(bytes: List<Byte>): String {
        if (bytes.isEmpty()) return "(empty)"
        var out = bytes.take(MAX_RAW_HEX_BYTES).joinToString(" ") { "%02x".format(it.toInt() and 0xFF) }
        if (bytes.size > MAX_RAW_HEX_BYTES) out += " … (${bytes.size} bytes total)"
        return out
    }

    /** [hex] over a raw frame. */
    fun hex(bytes: ByteArray): String = hex(bytes.toList())

    /** 5/MG result-code label, matching the body-location probe's table. */
    fun resultLabel(code: Int): String = when (code) {
        0 -> "FAILURE"
        1 -> "SUCCESS"
        2 -> "PENDING"
        3 -> "UNSUPPORTED"
        else -> "result$code"
    }
}

/**
 * The running result of one enumeration probe, rendered into the copyable text the Devices dialog and
 * the strap log both show. Pure and order-dependent (start → next… → finish). Twin of Swift
 * `FeatureFlagProbeReport`; [render] is byte-identical across platforms.
 */
class FeatureFlagProbeReport(
    private val family: DeviceFamily,
    /**
     * Which enumerate pair this walk drives — 117/118 or 115/116. The walk logic is identical; only the
     * opcodes and the words differ, so neither namespace can drift from the other's terminator rules.
     */
    val namespace: FeatureFlagProbe.Namespace = FeatureFlagProbe.FEATURE_FLAG_NAMESPACE,
) {

    private val _keys = mutableListOf<String>()
    /** Key names collected, in the order the strap reported them. */
    val keys: List<String> get() = _keys

    private val _trace = mutableListOf<String>()
    /** Trace lines: one per reply plus any failure notes. */
    val trace: List<String> get() = _trace

    /** SEND_NEXT replies seen. Bounds the walk (see [noteNext]). */
    var steps: Int = 0
        private set

    /** The count the strap reported for START, when it answered. */
    var reportedCount: Int? = null
        private set

    /** The same count read as a single byte (`record[1]`), when the record carried one. */
    var reportedCountSingleByte: Int? = null
        private set

    /** `record[2]` — the byte a u16 reading treats as the count's high half. */
    var reportedCountHighByte: Int? = null
        private set

    /** Result code of the START reply on 5/MG (null on 4.0, or before it lands). */
    var startResult: Int? = null
        private set

    /**
     * Entries the strap flagged as real keys whose NAME did not decode, and which the walk stepped over
     * rather than stopping at. Surfaced in the report so a dump with holes never reads as a complete list.
     */
    var skipped: Int = 0
        private set

    /** Replies carrying `validKey = 0` WITHOUT the 0xFF end marker, which the walk stepped over. */
    var emptySlots: Int = 0
        private set

    /** True once any `validKey = 0` reply arrived without the 0xFF marker. */
    var sawEmptySlot: Boolean = false
        private set

    /** True once `index = 0xFF` arrived. */
    var sawEndMarker: Boolean = false
        private set

    /**
     * True when the 0xFF reply ALSO carried `validKey = 0` — i.e. both terminator conditions fired on one
     * frame, and that run cannot say which one the firmware meant. This is what a 5/MG served on 115/116.
     */
    var endMarkerAlsoCarriedInvalidFlag: Boolean = false
        private set

    /**
     * Replies the strap served AFTER the first `validKey = 0`. Any value above zero is the decisive
     * observation: the list did not end there.
     */
    var repliesAfterFirstEmptySlot: Int = 0
        private set

    /** Key names collected after the first `validKey = 0` — keys a walk that stopped there would lose. */
    var keysAfterFirstEmptySlot: Int = 0
        private set

    /**
     * Replies after the first `validKey = 0` that the FIRMWARE flagged as real entries, whether or not
     * this parser could decode their names.
     *
     * This — not the decoded-key count — is what makes the empty-slot reading decisive. #874's rule applies
     * to the conclusion as much as to the walk: if the strap named an entry past the hole and our ASCII
     * filter declined it, the list still continued, and reporting "inconclusive" there would be our
     * parser's limitation deciding a question about the firmware.
     */
    var validEntriesAfterFirstEmptySlot: Int = 0
        private set

    /** Replies taken past the strap's announced count, under [FeatureFlagProbe.COUNT_OVERSHOOT_ALLOWANCE]. */
    var repliesPastAnnouncedCount: Int = 0
        private set

    /** Set once the walk stopped for a reason we can name. */
    var stopReason: String? = null
        private set

    /** The same reason as a code, so a caller (or a test) can branch on it rather than on prose. */
    var stopCode: FeatureFlagProbe.StopCode? = null
        private set

    /**
     * True once the walk has a reason to stop. The BLE driver consults this after EVERY reply, so a
     * refusal recorded on the START reply ends the run instead of being stepped over into the next verb.
     */
    val hasStopped: Boolean get() = stopCode != null

    /** The index the previous reply carried, for spotting a cursor that stopped advancing. */
    private var lastIndex: Int? = null

    /** Length of the current unbroken run of `validKey = 0` replies, reset by any valid entry. */
    private var consecutiveEmptySlots = 0

    /** Record the START reply. */
    fun noteStart(r: FeatureFlagProbe.StartResponse) {
        reportedCount = r.count
        reportedCountSingleByte = r.singleByteCount
        reportedCountHighByte = r.countHighByte
        startResult = r.resultCode
        var line = "${namespace.startLabel}(${namespace.startCmd}) → revision=${r.revision} count=${r.count}"
        r.resultCode?.let { line += " result=${FeatureFlagProbe.resultLabel(it)}($it)" }
        line += " raw=${FeatureFlagProbe.hex(r.record)}"
        if (!r.countIsPlausible) {
            line += "  ⚠︎ count outside 1…${FeatureFlagProbe.MAX_FLAGS} — treated as unknown, the walk " +
                "still stops on the strap's own end marker"
        }
        _trace.add(line)
        if (r.resultCode == 3) {
            stopReason = "strap refused ${namespace.startLabel}(${namespace.startCmd}) with UNSUPPORTED(3)"
            stopCode = FeatureFlagProbe.StopCode.UNSUPPORTED
        }
    }

    /**
     * Record one SEND_NEXT reply. Returns true when the walk should continue.
     *
     * The decision order IS the experiment. `index = 0xFF` ends the walk, because that marker is the one
     * thing a strap has served here unambiguously. `validKey = 0` on its own does NOT end it: the walk
     * steps over the entry, sends the next-record verb again, and records what comes back — the only way
     * to tell "end of list" from "empty slot" apart. Everything past that point is a CLIENT-side bound,
     * and each one names itself in [stopCode] so a walk that ended on our arithmetic can never be read as
     * a walk the strap ended.
     */
    fun noteNext(r: FeatureFlagProbe.NextResponse): Boolean {
        steps += 1
        if (sawEmptySlot) repliesAfterFirstEmptySlot += 1
        var line = "${namespace.nextLabel}(${namespace.nextCmd}) → index=${r.index} validKey=${r.validKey}"
        r.key?.let { line += " key=\"$it\"" }
        r.resultCode?.let { line += " result=${FeatureFlagProbe.resultLabel(it)}($it)" }
        line += " raw=${FeatureFlagProbe.hex(r.record)}"
        _trace.add(line)

        // 0. An explicit refusal. UNSUPPORTED(3) says the firmware does not serve this verb, so nothing in
        // the record is meaningful and there is nothing to walk. Checked FIRST, before any field is acted
        // on, and named as the strap's answer rather than as one of our bounds.
        if (r.resultCode == 3) {
            stopReason = "strap refused ${namespace.nextLabel}(${namespace.nextCmd}) with UNSUPPORTED(3)"
            stopCode = FeatureFlagProbe.StopCode.UNSUPPORTED
            return false
        }

        // 1. The strap's own unambiguous end marker. Nothing overrides this.
        if (r.isExhausted) {
            sawEndMarker = true
            if (!r.validKey) {
                endMarkerAlsoCarriedInvalidFlag = true
                _trace[_trace.size - 1] = _trace[_trace.size - 1] +
                    "  (index=0xFF AND validKey=0 on the same reply — both terminator conditions at once)"
            }
            stopReason = "cursor exhausted (index 0xFF)"
            stopCode = FeatureFlagProbe.StopCode.END_MARKER
            return false
        }

        // 2. `validKey = 0` with no end marker: the ambiguous case. Step over it and keep asking.
        if (r.isEmptySlot) {
            val parked = lastIndex == r.index
            lastIndex = r.index
            emptySlots += 1
            consecutiveEmptySlots += 1
            val runLength = consecutiveEmptySlots
            sawEmptySlot = true
            _trace[_trace.size - 1] = _trace[_trace.size - 1] +
                "  (validKey=0 without the 0xFF marker — treated as an EMPTY SLOT, walk continues)"
            if (parked) {
                // The cursor did not move. A firmware that means "end of list" parks there and repeats
                // itself, so this is the observation that settles the ambiguity the other way — and it
                // costs two round-trips rather than a full cap's worth.
                stopReason = "validKey=0 repeated at index ${r.index} without advancing — the cursor is " +
                    "parked, so on this firmware validKey=0 IS a terminator"
                stopCode = FeatureFlagProbe.StopCode.EMPTY_SLOT_CURSOR_PARKED
                return false
            }
            if (runLength >= FeatureFlagProbe.MAX_CONSECUTIVE_EMPTY_SLOTS) {
                stopReason = "$runLength consecutive validKey=0 replies (cap " +
                    "${FeatureFlagProbe.MAX_CONSECUTIVE_EMPTY_SLOTS}) — a CLIENT-side bound, not the strap's"
                stopCode = FeatureFlagProbe.StopCode.EMPTY_SLOT_RUN_CAP
                return false
            }
        } else {
            lastIndex = r.index
            consecutiveEmptySlots = 0
            if (sawEmptySlot) validEntriesAfterFirstEmptySlot += 1
            if (r.isSkippable) {
                // Our decode declined the name; the strap still says the entry is real and may have more
                // after it. Count it so a partial dump describes itself instead of looking complete.
                skipped += 1
                _trace[_trace.size - 1] = _trace[_trace.size - 1] +
                    "  (name did not decode — skipped, walk continues)"
            }
            r.key?.let {
                if (!_keys.contains(it)) {
                    _keys.add(it)
                    if (sawEmptySlot) keysAfterFirstEmptySlot += 1
                }
            }
        }

        // 3. Bound the walk on REPLIES, not on distinct keys: a firmware whose cursor never advances would
        // repeat one name forever, and a key-count bound would never stop writing the verb to the strap.
        if (steps >= FeatureFlagProbe.MAX_FLAGS) {
            stopReason = "safety cap of ${FeatureFlagProbe.MAX_FLAGS} replies reached"
            stopCode = FeatureFlagProbe.StopCode.STEP_CAP
            return false
        }
        // 4. The announced count, PLUS an overshoot, so the strap gets to end its own list. On the one
        // 117/118 walk this project has, `steps >= count` was the only thing that stopped it — no marker,
        // no validKey=0 — which means that list was never observed to end at all.
        val count = reportedCount
        if (count != null && count > 0 && count <= FeatureFlagProbe.MAX_FLAGS) {
            if (steps > count) repliesPastAnnouncedCount = steps - count
            if (steps >= count + FeatureFlagProbe.COUNT_OVERSHOOT_ALLOWANCE) {
                stopReason = "walked the $count entries the strap announced plus " +
                    "${FeatureFlagProbe.COUNT_OVERSHOOT_ALLOWANCE} more — a CLIENT-side bound; the strap " +
                    "never sent an end marker, so the list is not known to end here"
                stopCode = FeatureFlagProbe.StopCode.ANNOUNCED_COUNT_OVERSHOOT
                return false
            }
        }
        return true
    }

    /**
     * Record a reply that could not be decoded. [frame], when supplied, is logged in full: a frame that
     * failed its CRC is still the only evidence of what the strap actually put on the wire.
     */
    fun noteFailure(f: FeatureFlagProbe.ParseFailure, command: Int, frame: ByteArray = ByteArray(0)) {
        val why = when (f) {
            FeatureFlagProbe.ParseFailure.CRC -> "CRC failed — frame rejected (never decoded)"
            FeatureFlagProbe.ParseFailure.ENVELOPE -> "not a COMMAND_RESPONSE envelope"
            FeatureFlagProbe.ParseFailure.WRONG_COMMAND -> "COMMAND_RESPONSE for a different command"
            FeatureFlagProbe.ParseFailure.TRUNCATED -> "record too short for the documented layout"
        }
        var line = "cmd $command reply not decoded: $why"
        if (frame.isNotEmpty()) line += " raw frame=${FeatureFlagProbe.hex(frame)}"
        _trace.add(line)
        if (stopReason == null) {
            stopReason = why
            stopCode = FeatureFlagProbe.StopCode.PARSE_FAILURE
        }
    }

    /** Record the strap answering nothing at all within the probe's window. */
    fun noteTimeout(command: Int, seconds: Int) {
        _trace.add("no COMMAND_RESPONSE for opcode $command within ${seconds}s")
        if (stopReason == null) {
            stopReason = "strap served no reply to opcode $command within ${seconds}s"
            stopCode = FeatureFlagProbe.StopCode.TIMEOUT
        }
    }

    /**
     * The announced count as a phrase for the verdict line, qualified when it falls outside the range a
     * real key list could occupy. [noteStart] already marks an implausible count in the trace, but the
     * verdict is the line that gets pasted into an issue, and restating a number the probe itself
     * distrusts as bare fact is the same over-claim in a smaller place. A plausible count renders
     * exactly as before, so the common report is unchanged.
     */
    private val announcedFlags: String
        get() {
            val n = reportedCount ?: 0
            val plausible = n > 0 && n <= FeatureFlagProbe.MAX_FLAGS
            return if (plausible) "$n ${namespace.entryNoun}(s)"
            else "an implausible $n ${namespace.entryNoun}(s)"
        }

    /**
     * What this run established about the two terminator conditions — the question the probe exists to
     * answer, stated in the report rather than left for a reader to reconstruct from the trace.
     */
    val terminatorFinding: String
        get() {
            if (sawEmptySlot && (validEntriesAfterFirstEmptySlot > 0 || sawEndMarker)) {
                var s = "DECISIVE — validKey=0 is an EMPTY/RETIRED SLOT on this firmware, not the end of " +
                    "the list: the strap served $repliesAfterFirstEmptySlot further repl(ies) after the " +
                    "first validKey=0"
                if (validEntriesAfterFirstEmptySlot > 0) {
                    s += ", $validEntriesAfterFirstEmptySlot of them flagged validKey=1"
                }
                if (keysAfterFirstEmptySlot > 0) s += ", naming $keysAfterFirstEmptySlot more key(s)"
                if (sawEndMarker) s += ", and ended on the index=0xFF marker"
                s += ". A walk that stopped on validKey=0 would have been truncated here."
                return s
            }
            if (stopCode == FeatureFlagProbe.StopCode.EMPTY_SLOT_CURSOR_PARKED) {
                // The DECISIVE label is kept, narrowed to what the run actually decides. "There is nothing
                // past it" is a step beyond the observation, and TWO firmwares emit this identical frame:
                // a list that genuinely ends at a parked sentinel, and a cursor that advances only on a
                // valid record — where validKey=0 is a SLOT, the walk is stuck on a hole, and keys may sit
                // behind it. The second is precisely the reading this probe exists to make testable.
                return "DECISIVE — validKey=0 is a TERMINATOR on this firmware: the next request returned " +
                    "the same index with validKey=0 again, so the cursor does not advance past it, so " +
                    "this walk cannot see anything beyond. Whether the list truly ends here is not " +
                    "separable from a firmware whose cursor parks on an empty slot."
            }
            if (sawEmptySlot) {
                return "INCONCLUSIVE — validKey=0 was served and the walk continued past it, but a " +
                    "client-side bound ended the run before the strap did. Nothing here separates 'end of " +
                    "list' from 'empty slot'."
            }
            if (sawEndMarker && endMarkerAlsoCarriedInvalidFlag) {
                return "AMBIGUOUS — the walk ended on a reply carrying index=0xFF AND validKey=0 " +
                    "together, so both terminator conditions fired at once and this run cannot say which " +
                    "one the firmware meant."
            }
            if (sawEndMarker) {
                return "index=0xFF ended the walk with validKey still true on the same reply, so the 0xFF " +
                    "marker alone terminates. validKey=0 was never served, so it is untested here."
            }
            return "NO TERMINATOR OBSERVED — neither validKey=0 nor index=0xFF was served in $steps " +
                "repl(ies); the walk ended on a CLIENT-side bound, so the strap's list is not known to " +
                "end where this report stops."
        }

    /** What the announced count actually says, including the reading it does not settle. */
    val countFinding: String?
        get() {
            val count = reportedCount ?: return null
            var s = "u16 LE read = $count"
            val single = reportedCountSingleByte
            val high = reportedCountHighByte
            if (single != null && high != null) {
                s += "; single-byte read = $single (high byte 0x%02x".format(high) + ")"
                s += if (high == 0) {
                    " — the two readings AGREE, so this reply does not establish the field's width"
                } else {
                    " — the two readings DISAGREE; the walk uses the u16 value and plausibility-checks it"
                }
            }
            s += ". Keys yielded: ${_keys.size}"
            if (skipped > 0) s += " (+$skipped undecodable)"
            if (emptySlots > 0) s += " (+$emptySlots empty slot(s))"
            if (_keys.size + skipped + emptySlots != count) s += " — MISMATCH against the announced $count"
            if (repliesPastAnnouncedCount > 0) {
                s += ". The strap kept answering $repliesPastAnnouncedCount repl(ies) past its own " +
                    "announced count."
            }
            return s
        }

    /** One-line summary of what the probe established. */
    val verdict: String
        get() {
            if (startResult == 3) {
                return "opcode ${namespace.startCmd} REJECTED by firmware (UNSUPPORTED) — this strap does not serve the enumerate verb"
            }
            if (_keys.isEmpty() && reportedCount == null) {
                return "no usable reply — the enumerate path is unconfirmed on this firmware"
            }
            // "named none" would blame the strap for OUR decode. If entries were skipped the strap did
            // name them and this parser rejected the names, which is the opposite conclusion and the one
            // a reader would carry into #103. Same class as [FeatureFlagProbe.NextResponse.isSkippable]:
            // never report our limitation as the strap's behaviour.
            if (_keys.isEmpty() && skipped > 0) {
                return "strap named $skipped ${namespace.entryNoun}(s), none of which decoded as printable ASCII within " +
                    "${FeatureFlagProbe.MAX_KEY_LENGTH} chars — this is our parser rejecting them, NOT " +
                    "the strap serving blanks; see the trace for the raw replies"
            }
            // Same discipline one condition over: with no 118 reply decoded, the walk never asked for a
            // single name, so "named none" would blame the strap for OUR timeout (or our parse failure).
            // [steps] counts decoded SEND_NEXT replies, so `steps == 0` is exactly "the key list was
            // never read" — the reachable case being the probe getting its START answer and then the 8s
            // timer firing on the first SEND_NEXT. What the strap would have named is unknown, and the
            // report has to say unknown. [stopReason], rendered directly under this line, names which of
            // the two it was. (#913, kept through this PR's rebase: the opcode names are now taken from
            // [namespace] so a 115/116 walk does not report itself as SEND_NEXT_FF(118).)
            if (_keys.isEmpty() && steps == 0) {
                return "strap announced $announcedFlags; no ${namespace.nextLabel}(${namespace.nextCmd}) " +
                    "reply was decoded — the key list was never read (inconclusive)"
            }
            if (_keys.isEmpty()) {
                // Both halves survive the merge with #913: its doubt about an implausible announced count
                // ([announcedFlags]), and this PR's namespace-aware noun.
                return "strap announced $announcedFlags but named none"
            }
            var s = "enumerated ${_keys.size} ${namespace.noun} key name(s)"
            if (skipped > 0) s += "; $skipped further name(s) did not decode"
            // A walk that ended on OUR bound is not a complete list, and the one-line summary is the line
            // that gets pasted into an issue. Say it here, not only four lines further down.
            if (stopCode == FeatureFlagProbe.StopCode.STEP_CAP ||
                stopCode == FeatureFlagProbe.StopCode.ANNOUNCED_COUNT_OVERSHOOT ||
                stopCode == FeatureFlagProbe.StopCode.EMPTY_SLOT_RUN_CAP
            ) {
                s += " — INCOMPLETE: the walk ended on a client-side bound, not on the strap's own end marker"
            }
            return s
        }

    /** The full copyable report (byte-identical to the Swift `render()`). */
    fun render(): String {
        val fam = if (family == DeviceFamily.WHOOP5) "WHOOP 5/MG" else "WHOOP 4.0"
        val sb = StringBuilder()
        sb.append("#761 ${namespace.title} — $fam\n")
        sb.append("Read-only: ${namespace.startLabel}(${namespace.startCmd}) + ")
        sb.append("${namespace.nextLabel}(${namespace.nextCmd}). No value is written; ")
        sb.append("SET_FF_VALUE(120) and SET_DEVICE_CONFIG_VALUE(119) are never sent from this path.\n")
        sb.append("\nVerdict: $verdict\n")
        stopReason?.let { sb.append("Stopped: $it\n") }
        stopCode?.let { sb.append("Stop code: ${it.code}\n") }
        sb.append("Terminator: $terminatorFinding\n")
        countFinding?.let { sb.append("Announced count: $it\n") }
        sb.append("\n${namespace.listHeading} reported by the strap (${_keys.size}")
        reportedCount?.let { sb.append(" of $it announced") }
        if (skipped > 0) sb.append(", $skipped name(s) did not decode and were skipped")
        if (emptySlots > 0) sb.append(", $emptySlots validKey=0 slot(s) stepped over")
        sb.append("):\n")
        if (_keys.isEmpty()) {
            sb.append("  (none)\n")
        } else {
            _keys.forEachIndexed { i, k -> sb.append("  %2d. ".format(i + 1)).append(k).append("\n") }
        }
        sb.append("\nExchange:\n")
        for (line in _trace) sb.append("  ").append(line).append("\n")
        return sb.toString()
    }
}
