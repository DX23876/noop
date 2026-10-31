import Foundation

/// #1303: find a WHOOP 5/MG strap serial inside the GET_HELLO (145) info block.
///
/// A stable per-strap id is the keystone the multi-strap work waits on, and today there is no strap
/// serial decoded anywhere: `BatteryPackInfo.serial` is the BATTERY PACK's, read via cmd 151 and
/// answered only by a 5/MG, so it identifies a removable part rather than the strap wearing it.
///
/// The 4.0 hunt has a capture aid already (the `GET_HELLO_HARVARD` (35) branch, which now reports
/// through this same probe — its payload carries a device key beside the serial). This is the 5/MG
/// half, and it needs no new traffic: the GET_HELLO block is ALREADY decoded for the text at `pay[16]`
/// and the firmware version at `pay[93]`. That text turned out to be the serial itself: on a WHOOP MG
/// (fw 50.41.1.0, 2026-10-31) it starts with the MG prefix "5AM", so the decoder publishes it as
/// `strap_serial`. The probe stays for firmwares where the block may be laid out differently.
///
/// ## Why this reports structure instead of dumping the block
///
/// The same response carries a SESSION TOKEN, which the decoder deliberately never reads. Dumping the
/// payload wholesale would put that token in a log, so this reports every printable run as
/// offset + length + class and prints the CONTENTS only of runs that could plausibly be the serial and
/// are not the already-known name: fully alphanumeric, [serialLength] characters long.
///
/// That rule is a filter, not a guarantee — a token that happened to be alphanumeric and serial-length
/// would print. Which is precisely why the caller gates this behind an opt-in diagnostic rather than
/// the default, shareable strap log.
///
/// Pure and Foundation-only, so it unit-tests with no strap, no BLE and no app.
public enum HelloIdentityProbe {

    /// ASCII digits/letters. A serial is alphanumeric; this is what separates a candidate from the
    /// punctuation-and-symbols runs that binary payloads produce by chance.
    private static func isAlnum(_ b: UInt8) -> Bool {
        (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b)
    }

    /// Printable-ASCII runs in a GET_HELLO payload, one line each, for a diagnostic log.
    ///
    /// - Parameters:
    ///   - payload: the GET_HELLO (145) response payload, token region included — nothing is stripped
    ///     before this call; the withholding happens here so a caller cannot get it wrong.
    ///   - knownNameOffset: where the decoder already reads the strap serial (16 on the pinned captures).
    ///     A mixed run starting there is labelled rather than printed.
    ///   - minRun: shortest printable run worth reporting. Below this, a binary payload produces noise.
    ///   - serialLength: run lengths that could be a serial. Outside it, contents are withheld.
    public static func candidateLines(payload: [UInt8],
                                      knownNameOffset: Int = 16,
                                      minRun: Int = 4,
                                      serialLength: ClosedRange<Int> = 6...20) -> [String] {
        var out: [String] = []
        var i = 0
        while i < payload.count {
            guard (32...126).contains(payload[i]) else { i += 1; continue }
            let start = i
            while i < payload.count, (32...126).contains(payload[i]) { i += 1 }
            let run = Array(payload[start..<i])
            guard run.count >= minRun else { continue }

            let alnum = run.allSatisfy(isAlnum)
            var line = "off=\(start) len=\(run.count) \(alnum ? "alnum" : "mixed")"
            // The known-name offset is LABELLED but not suppressed. `knownNameOffset` is an assumption
            // taken from one firmware capture, and this is a discovery tool: if a firmware moved the name
            // and the serial landed here, suppressing the value would hide the exact thing being hunted.
            // On a real MG the run at 16 IS the strap serial (it starts with the MG prefix "5AM"), which the
            // decoder now publishes as `strap_serial`; this probe sits behind an opt-in diagnostic, so
            // printing it here is the same exposure as before.
            if start == knownNameOffset { line += " (strap serial, decoded)" }
            if alnum, serialLength.contains(run.count) {
                line += " \"\(String(decoding: run, as: UTF8.self))\""
            } else if start != knownNameOffset {
                line += " (withheld)"
            }
            out.append(line)
        }
        return out
    }

    /// One log line for the whole block: its length, and every candidate run.
    ///
    /// The length is reported even when nothing prints, because "no printable runs at all" is itself the
    /// answer — it says the serial is not ASCII in this block and the search moves elsewhere.
    ///
    /// - Parameter block: which response this payload came from, for the line's prefix. Defaults to the
    ///   5/MG `GET_HELLO` this probe was written for; the WHOOP 4.0 `GET_HELLO_HARVARD(35)` capture aid
    ///   passes its own so one log can carry both without the two reading as the same frame.
    public static func report(payload: [UInt8],
                              block: String = "HELLO(145)",
                              knownNameOffset: Int = 16,
                              minRun: Int = 4,
                              serialLength: ClosedRange<Int> = 6...20) -> String {
        let lines = candidateLines(payload: payload, knownNameOffset: knownNameOffset,
                                   minRun: minRun, serialLength: serialLength)
        let body = lines.isEmpty ? "none" : lines.joined(separator: "; ")
        return "\(block) block len=\(payload.count) runs: \(body)"
    }
}
