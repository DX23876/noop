import Foundation

/// Maps the app's persistence-relevant lifecycle edges onto the reason carried through Collector logs.
/// The app and tests call this same seam, so lifecycle routing is exercised without UIKit on Linux.
public enum StandardHRLifecycleFlush {
    public enum Event {
        case background
        case termination
    }

    public static func run(
        event: Event,
        flush: (LivePersistTrace.StandardHRFlushReason) async -> Void
    ) async {
        switch event {
        case .background:
            await flush(.background)
        case .termination:
            await flush(.termination)
        }
    }
}

/// A live HR/R-R batch failed to persist and was re-buffered.
///
/// `Collector` re-queues the frames and swallows the error, so a store rejecting every insert produces a
/// log full of `rr emit … offered=N` and no indication that none of it landed. That is the worst shape a
/// diagnostic gap can take: the instrumentation that exists reads like success.
///
/// Twin of the Kotlin `liveInsertFailedLine` in `com.noop.ble.StalledLinkDiagnostics`, so an Android and
/// an Apple log of the same failure compare directly. Rendered strings match for ASCII (store errors).
/// The 200-character bound is not a Unicode-identical truncation: Kotlin `take(200)` counts UTF-16 code
/// units and Swift `prefix(200)` counts grapheme clusters. Store error descriptions are ASCII, which is
/// the load-bearing case. The Kotlin side lives beside its caller in the BLE package; this one lives here
/// because `Collector` is app-target Swift with no default CI, and the package is where the other
/// emitted-line builders (`Spo2ReTrace`, `SleepStager+Trace`, `ConnectionReadout`) already sit and get tested.
public enum LivePersistTrace {

    public enum StandardHRFlushReason: String {
        case cadence
        case disconnect
        case background
        case termination
        case explicit
    }

    /// Bounded standard-HR transport-state diagnostics. These lines describe host observation and
    /// buffer/persistence state only; they carry no physiological measurements and make no claim
    /// about sensor-origin time or unobserved loss.
    public static func standardHRHostReceivedLine(
        hostUnixSeconds: Int,
        acceptedHRRows: Int, acceptedRRRows: Int,
        rejectedHRRows: Int, rejectedRRRows: Int,
        pendingHRRows: Int, pendingRRRows: Int
    ) -> String {
        "standard-hr transport host-received hostUnixSec=\(hostUnixSeconds)"
            + " acceptedHRRows=\(acceptedHRRows) acceptedRRRows=\(acceptedRRRows)"
            + " rejectedHRRows=\(rejectedHRRows) rejectedRRRows=\(rejectedRRRows)"
            + " pendingHRRows=\(pendingHRRows) pendingRRRows=\(pendingRRRows)"
    }

    public static func standardHRFlushAttemptLine(
        reason: StandardHRFlushReason, offeredHRRows: Int, offeredRRRows: Int
    ) -> String {
        "standard-hr transport flush-attempt reason=\(reason.rawValue)"
            + " offeredHRRows=\(offeredHRRows) offeredRRRows=\(offeredRRRows)"
    }

    public static func standardHRFlushSucceededLine(
        reason: StandardHRFlushReason, offeredHRRows: Int, offeredRRRows: Int,
        insertedHRRows: Int, insertedRRRows: Int
    ) -> String {
        "standard-hr transport flush-succeeded reason=\(reason.rawValue)"
            + " offeredHRRows=\(offeredHRRows) offeredRRRows=\(offeredRRRows)"
            + " insertedHRRows=\(insertedHRRows) insertedRRRows=\(insertedRRRows)"
    }

    public static func standardHRRebufferedForRetryLine(
        reason: StandardHRFlushReason, attemptedHRRows: Int, attemptedRRRows: Int,
        pendingHRRows: Int, pendingRRRows: Int, consecutiveFailures: Int
    ) -> String {
        "standard-hr transport rebuffered-for-retry reason=\(reason.rawValue)"
            + " attemptedHRRows=\(attemptedHRRows) attemptedRRRows=\(attemptedRRRows)"
            + " pendingHRRows=\(pendingHRRows) pendingRRRows=\(pendingRRRows)"
            + " consecutiveFailures=\(consecutiveFailures)"
    }

    /// - Parameters:
    ///   - transport: which live path failed. There are TWO — the standard 0x2A37 reading and the puffin
    ///     REALTIME_DATA batch (#1118) — and they fail independently. A line that did not say which would
    ///     leave a reader unable to tell one dead transport from a dead store, the first fork in the
    ///     diagnosis.
    ///   - errorName: the error's type name. Spelled `throwableName` in the Kotlin twin; the rendered
    ///     line is identical.
    ///   - consecutiveFailures: matters more than any single error. One failure is the transient the
    ///     re-buffer exists to absorb; a climbing count is a store that will never accept these rows, and
    ///     only the count separates them.
    public static func liveInsertFailedLine(
        transport: String,
        errorName: String,
        message: String?,
        hrFrames: Int,
        rrFrames: Int,
        consecutiveFailures: Int
    ) -> String {
        // Bounded like the Kotlin `take(200)`: a full error description can be enormous, and the useful
        // cases (a full disk, a corrupted database, a schema mismatch) are distinguished well inside it.
        // ASCII-only twin: `take` is UTF-16 code units, `prefix` is grapheme clusters.
        let detail = message.flatMap { m -> String? in
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : ": " + String(m.prefix(200))
        } ?? ""
        let run = consecutiveFailures >= 2
            ? " \(consecutiveFailures) consecutive failures — these rows are not landing and the re-buffer is"
                + " not recovering them."
            : " Re-buffered for the next cadence."
        return "Live persist FAILED on \(transport) — \(errorName)\(detail) (hr=\(hrFrames) rr=\(rrFrames))."
            + run
    }

    /// Rate limit for ``liveInsertFailedLine(transport:errorName:message:hrFrames:rrFrames:consecutiveFailures:)``.
    ///
    /// The live cadence is seconds, so an unconditional log would bury the rest of the capture under a
    /// failure it has already reported. The gap is deliberately long: this line establishes THAT inserts
    /// are failing and roughly for how long, which one line a minute answers as well as sixty.
    ///
    /// A zero `lastEmitMs` must emit — the first failure is the one most worth having. A BACKWARDS clock
    /// emits too: wall time can step back, and comparing only forwards would strand `lastEmitMs` in the
    /// future and silence the line until real time caught up. Byte-identical rule to the Kotlin twin.
    public static func shouldEmitLiveInsertFailure(
        lastEmitMs: Int64,
        nowMs: Int64,
        minGapMs: Int64 = 60_000
    ) -> Bool {
        lastEmitMs <= 0 || nowMs < lastEmitMs || nowMs - lastEmitMs >= minGapMs
    }
}
