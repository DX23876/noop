import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// The editor offers a "Move anyway" confirm for a corrected window that touches none of the night's
/// recorded data, and promises the night will move there. That consent used to reach
/// `SleepGroupEdit.plan`, which by contract returns an EMPTY plan for a disjoint window, so
/// `editSleepGroupTimes` aborted with a bare `nil`: the sheet closed, nothing was written, and the user
/// saw a correction that "was not applied". These pin the consented path and the refusal without consent.
final class SleepGroupEditRelocationTests: XCTestCase {

    private let canonicalId = "my-whoop"

    /// A night ten days back, so every window used here is comfortably in the past for
    /// `SleepEditGuard.clampedEditWindow`.
    private var nightStart: Int { Int(Date().timeIntervalSince1970) - 10 * 86_400 }

    private func session(_ start: Int, _ end: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9, restingHr: 52,
                           avgHrv: 60, stagesJSON: nil)
    }

    /// Consented move: the carrier row takes the new window (keeping its immutable key), the other
    /// fragment is retired, and the caller gets the retired snapshot back for the grouped Undo.
    @MainActor
    func testConfirmedRelocationWritesTheNewWindow() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        let t0 = nightStart
        let group = [session(t0, t0 + 3_600), session(t0 + 2 * 3_600, t0 + 8 * 3_600)]
        _ = try await store.upsertSleepSessions(group, deviceId: canonicalId)

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)

        let newStart = t0 + 30 * 3_600, newEnd = t0 + 36 * 3_600
        let outcome = await repo.editSleepGroupTimes(group, newStartTs: newStart, newEndTs: newEnd,
                                                     allowRelocation: true)
        guard case .success(let result) = outcome else {
            return XCTFail("a consented move must succeed, got \(outcome)")
        }
        XCTAssertEqual(result.retired.map(\.session.startTs), [t0],
                       "the shorter fragment is retired; the longest carries the night")

        let rows = try await store.sleepSessions(deviceId: canonicalId, from: 0,
                                                 to: t0 + 40 * 3_600, limit: 10)
        XCTAssertEqual(rows.count, 1, "the retired fragment must be gone")
        XCTAssertEqual(rows[0].startTs, t0 + 2 * 3_600, "the immutable key must not move")
        XCTAssertEqual(rows[0].effectiveStartTs, newStart)
        XCTAssertEqual(rows[0].endTs, newEnd)
        XCTAssertTrue(rows[0].userEdited)
    }

    /// Without consent the same window is refused with a REPORTABLE reason and writes nothing — an
    /// ordinary time correction that overlaps nothing is a mis-set date, not a request to move a night.
    @MainActor
    func testDisjointEditWithoutConsentReportsNoOverlapAndChangesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        let t0 = nightStart
        let group = [session(t0, t0 + 8 * 3_600)]
        _ = try await store.upsertSleepSessions(group, deviceId: canonicalId)

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)

        let outcome = await repo.editSleepGroupTimes(group, newStartTs: t0 + 30 * 3_600,
                                                     newEndTs: t0 + 36 * 3_600)
        XCTAssertEqual(outcome.failureReasonForTesting, .noOverlap)

        let rows = try await store.sleepSessions(deviceId: canonicalId, from: 0,
                                                 to: t0 + 40 * 3_600, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].effectiveStartTs, t0, "the night must be untouched")
        XCTAssertEqual(rows[0].endTs, t0 + 8 * 3_600)
        XCTAssertFalse(rows[0].userEdited)
    }

    /// An impossible window is refused by the persistence clamp with its own reason, so the UI can say
    /// which guard rejected it rather than closing the sheet silently.
    @MainActor
    func testInvertedWindowReportsInvalidWindow() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonicalId, mac: nil, name: "WHOOP")
        let t0 = nightStart
        let group = [session(t0, t0 + 8 * 3_600)]
        _ = try await store.upsertSleepSessions(group, deviceId: canonicalId)

        let repo = Repository(deviceId: canonicalId)
        repo.setStoreForTesting(store)

        let outcome = await repo.editSleepGroupTimes(group, newStartTs: t0 + 8 * 3_600, newEndTs: t0,
                                                     allowRelocation: true)
        XCTAssertEqual(outcome.failureReasonForTesting, .invalidWindow)
    }
}

private extension Result where Success == SleepGroupEditResult, Failure == SleepEditFailure {
    /// The failure reason, or nil on success — keeps the assertions above to one line.
    var failureReasonForTesting: SleepEditFailure? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
}
