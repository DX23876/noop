import XCTest
import WhoopProtocol
@testable import WhoopStore

final class StandardHRMappingTests: XCTestCase {
    func testStandardHRMapsToStreams() throws {
        let s = StandardHRMapping.samples(fromHR: 72, rr: [820, 815], at: 1_750_000_000)
        XCTAssertEqual(s.hr.map { $0.bpm }, [72])
        XCTAssertEqual(s.hr.map { $0.ts }, [1_750_000_000])
        XCTAssertEqual(s.rr.map { $0.rrMs }, [820, 815])
        XCTAssertEqual(s.rr.map { $0.ts }, [1_750_000_000, 1_750_000_000])
    }

    func testStandardHRWithNoRRLeavesRREmpty() throws {
        let s = StandardHRMapping.samples(fromHR: 60, rr: [], at: 1_000)
        XCTAssertEqual(s.hr.map { $0.bpm }, [60])
        XCTAssertTrue(s.rr.isEmpty)
    }

    func testStandardHRContactIsMappedAsAStableEvent() throws {
        let s = StandardHRMapping.samples(
            fromHR: 72,
            rr: [],
            contact: .supportedDetected,
            at: 1_750_000_000
        )
        XCTAssertEqual(s.events, [
            WhoopEvent(
                ts: 1_750_000_000,
                kind: StandardHRMapping.contactEventKind,
                payload: ["contact": .string("supported_detected")]
            )
        ])
    }

    func testLegacyMappingDoesNotFabricateContact() throws {
        let s = StandardHRMapping.samples(fromHR: 72, rr: [], at: 1_750_000_000)
        XCTAssertTrue(s.events.isEmpty)
    }

    func testContactSurvivesInsertAndReadWhileLegacyRowsStayAbsent() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "standard-strap", mac: nil, name: nil)
        _ = try await store.insert(
            StandardHRMapping.samples(fromHR: 72, rr: [], contact: .supportedNotDetected, at: 100),
            deviceId: "standard-strap"
        )
        _ = try await store.insert(
            StandardHRMapping.samples(fromHR: 73, rr: [], at: 101),
            deviceId: "standard-strap"
        )

        let contacts = try await store.standardHRContacts(
            deviceId: "standard-strap", from: 0, to: 200, limit: 10
        )
        XCTAssertEqual(contacts, [
            StandardHRContactSample(ts: 100, contact: .supportedNotDetected)
        ])
    }

    func testOnlyHRandRRStreamsArePopulated() throws {
        // A chest strap reports nothing else — every other stream must stay empty.
        let s = StandardHRMapping.samples(fromHR: 88, rr: [700], at: 42)
        XCTAssertTrue(s.spo2.isEmpty)
        XCTAssertTrue(s.skinTemp.isEmpty)
        XCTAssertTrue(s.resp.isEmpty)
        XCTAssertTrue(s.gravity.isEmpty)
        XCTAssertTrue(s.steps.isEmpty)
        XCTAssertTrue(s.ppgHr.isEmpty)
        XCTAssertTrue(s.events.isEmpty)
        XCTAssertTrue(s.battery.isEmpty)
    }

    func testContactSampleParsesPayloadJSONAndDoesNotTreatParseFailureAsAbsence() throws {
        let detected = try StandardHRMapping.contactSample(
            ts: 100,
            payloadJSON: #"{"extra":true,"contact":"supported_detected"}"#
        )
        XCTAssertEqual(detected, StandardHRContactSample(ts: 100, contact: .supportedDetected))

        XCTAssertThrowsError(try StandardHRMapping.contactSample(ts: 101, payloadJSON: "not-json"))
        XCTAssertThrowsError(try StandardHRMapping.contactSample(ts: 102, payloadJSON: "{}"))
    }
}
