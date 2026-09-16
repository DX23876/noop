import XCTest
@testable import StrandTraining

final class RoutineScheduleEditingTests: XCTestCase {
    func testAssigningWeekdaysKeepsOtherRoutinesAndTheirOrder() {
        let edited = UUID()
        let other = UUID()
        let original: [TrainingWeekday: [UUID]] = [
            .monday: [other, edited], .wednesday: [other], .friday: [edited]
        ]

        let updated = RoutineEditing.schedule(original, assigning: edited, to: [.wednesday, .friday])

        XCTAssertEqual(updated[.monday], [other])
        XCTAssertEqual(updated[.wednesday], [other, edited])
        XCTAssertEqual(updated[.friday], [edited])
        XCTAssertNil(updated[.sunday])
        XCTAssertEqual(RoutineEditing.weekdays(of: edited, in: updated), [.wednesday, .friday])
        XCTAssertEqual(RoutineEditing.weekdays(of: other, in: updated), [.monday, .wednesday])
    }

    func testUnchangedAssignmentLeavesTheScheduleEqual() {
        let routine = UUID()
        let original: [TrainingWeekday: [UUID]] = [.tuesday: [routine]]
        XCTAssertEqual(RoutineEditing.schedule(original, assigning: routine, to: [.tuesday]), original)
    }
}
