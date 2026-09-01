import Foundation
import WhoopProtocol

/// Pure, testable mapping from a single standard-BLE Heart-Rate reading (0x2A37) onto the
/// datastore's `Streams` shape, so an isolated generic-strap source (`StandardHRSource` in the
/// app target) can persist its samples through the SAME `StreamStore.insert` path the WHOOP
/// pipeline uses — without duplicating the row-construction logic in the app target where it
/// can't be unit-tested.
///
/// A chest strap (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio broadcast) only ever
/// reports HR, (optionally) R-R intervals, and its standard contact flags over 0x2A37; every other
/// stream (spo2, skin temp, resp, gravity, steps, ppgHr, battery) is left empty.
public enum StandardHRMapping {
    /// `event.kind` used for a standard BLE sensor-contact reading. The generic event table is the
    /// established durable stream for additive decoded signals, so this needs no schema migration.
    public static let contactEventKind = "STANDARD_HR_CONTACT"

    /// Should this reading record a contact event, given the last one recorded?
    ///
    /// Contact is a STATE, not a measurement: it changes when the strap goes on or comes off, a handful
    /// of times a day, while the standard 0x2A37 stream arrives at ~1 Hz. Writing one row per reading
    /// stored ~86,400 rows a day per device to say the same thing 86,390 times, into a local-first
    /// database, for a read side that reconstructs "the value at or before ts" and therefore only ever
    /// needed the changes.
    ///
    /// `previous == nil` records, so every session opens with its starting state and a reader never has
    /// to assume one. Twin of Kotlin `StandardHrMapping.shouldRecordContact`.
    public static func shouldRecordContact(previous: StandardHRContact?,
                                           current: StandardHRContact) -> Bool {
        previous != current
    }

    /// Build a `Streams` carrying one HR sample and zero-or-more R-R intervals, all stamped at the
    /// same wall-clock `ts` (unix seconds). Pure → unit-testable.
    public static func samples(fromHR hr: Int, rr: [Int], contact: StandardHRContact? = nil,
                               at ts: Int) -> Streams {
        let events = contact.map { [
            WhoopEvent(ts: ts, kind: contactEventKind, payload: ["contact": .string($0.rawValue)])
        ] } ?? []
        return Streams(
            hr: [HRSample(ts: ts, bpm: hr)],
            rr: rr.map { RRInterval(ts: ts, rrMs: $0) },
            events: events
        )
    }

    /// Parse a persisted `STANDARD_HR_CONTACT` `payloadJSON`. Throws on malformed JSON or a missing /
    /// unknown `contact` field so a parse failure is not the same as "no contact event".
    public static func contactSample(ts: Int, payloadJSON: String) throws -> StandardHRContactSample {
        let payload = try JSONDecoder().decode([String: ParsedValue].self, from: Data(payloadJSON.utf8))
        guard case let .string(raw)? = payload["contact"] else {
            throw ContactSampleError.missingContact
        }
        guard let contact = StandardHRContact(rawValue: raw) else {
            throw ContactSampleError.unknownContact(raw)
        }
        return StandardHRContactSample(ts: ts, contact: contact)
    }

    public enum ContactSampleError: Error, Equatable {
        case missingContact
        case unknownContact(String)
    }
}

/// One persisted standard-BLE sensor-contact reading. Legacy HR rows have no companion event and are
/// therefore absent from this stream instead of being guessed as any contact state.
public struct StandardHRContactSample: Equatable, Sendable {
    public let ts: Int
    public let contact: StandardHRContact
    public init(ts: Int, contact: StandardHRContact) {
        self.ts = ts
        self.contact = contact
    }
}
