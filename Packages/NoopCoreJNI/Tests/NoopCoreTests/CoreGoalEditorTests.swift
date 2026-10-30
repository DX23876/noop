import Foundation
import XCTest
@testable import NoopCore

/// The one-page goal editor on Android is `CoachGoalEditorView`: it loads a goal as typed, judges the draft with the
/// shared gates and saves through `CoachGoalStore.commit`, which keeps the goal's identity and route.
@MainActor
final class CoreGoalEditorTests: XCTestCase {
    private var saved: CoachGoalStore!

    override func setUp() {
        super.setUp()
        saved = CoachGoalStore.shared
        CoachGoalStore.shared = CoachGoalStore(defaults: UserDefaults(suiteName: "goal-editor-\(UUID().uuidString)")!)
    }

    override func tearDown() {
        CoachGoalStore.shared = saved
        super.tearDown()
    }

    private func pastDue() -> CoachGoal {
        CoachGoal(kind: .run, title: "5k without stopping", baseline: 3, target: 5,
                  targetDate: Date().addingTimeInterval(-86_400))
    }

    func testLoadFillsTheFieldsFromTheGoal() {
        let goal = pastDue()
        CoachGoalStore.shared.goals = [goal]
        let s = CoreGoalEditor.run("goals.editor.load", ["id": goal.id.uuidString], weightKg: 0)
        XCTAssertTrue(s.found)
        XCTAssertEqual(s.draft.title, "5k without stopping")
        XCTAssertEqual(s.draft.baseline, "3")
        XCTAssertEqual(s.draft.target, "5")
        XCTAssertTrue(s.draft.hasTargetDate)
        XCTAssertTrue(s.draft.targetDateTouched, "an existing goal's own answer counts as the wearer's choice")
        XCTAssertTrue(s.canSave)
        XCTAssertNil(s.limit, "editing a goal never collides with itself")
    }

    /// "Extend the date": a later date keeps the goal's id, history and creation date.
    func testExtendingTheDateKeepsTheGoal() throws {
        let goal = pastDue()
        CoachGoalStore.shared.goals = [goal]
        var s = CoreGoalEditor.run("goals.editor.load", ["id": goal.id.uuidString], weightKg: 0)
        let later = Date().addingTimeInterval(30 * 86_400).timeIntervalSince1970
        var draft = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s.draft)) as? [String: Any])
        draft["targetDate"] = later
        s = CoreGoalEditor.run("goals.editor.save", ["id": goal.id.uuidString, "draft": draft], weightKg: 0)
        XCTAssertTrue(s.saved)
        let stored = try XCTUnwrap(CoachGoalStore.shared.goal(id: goal.id))
        XCTAssertEqual(CoachGoalStore.shared.goals.count, 1)
        XCTAssertEqual(stored.targetDate?.timeIntervalSince1970 ?? 0, later, accuracy: 1)
        XCTAssertEqual(stored.createdAt, goal.createdAt)
        XCTAssertEqual(stored.history.last?.what, "Goal updated")
    }

    func testSameStartAndTargetBlocksSave() {
        let goal = pastDue()
        CoachGoalStore.shared.goals = [goal]
        let s = CoreGoalEditor.run("goals.editor", ["id": goal.id.uuidString,
            "draft": ["kind": "run", "title": "5k", "baseline": "4", "target": "4,0", "hasTargetDate": true,
                      "targetDateTouched": true, "targetDate": Date().timeIntervalSince1970 + 86_400]], weightKg: 0)
        XCTAssertFalse(s.rangeIsUsable)
        XCTAssertFalse(s.canSave)
    }

    func testKindFollowsTheDateDefaultUntilTouched() {
        let s = CoreGoalEditor.run("goals.editor.kind", ["draft": ["kind": "run", "title": "x", "hasTargetDate": true,
                                                                   "targetDateTouched": false], "to": "recovery"], weightKg: 0)
        XCTAssertEqual(s.draft.kind, "recovery")
        XCTAssertFalse(s.draft.hasTargetDate)
        XCTAssertNotNil(s.kindNote)
        let kept = CoreGoalEditor.run("goals.editor.kind", ["draft": ["kind": "run", "title": "x", "hasTargetDate": true,
                                                                      "targetDateTouched": true], "to": "recovery"], weightKg: 0)
        XCTAssertTrue(kept.draft.hasTargetDate)
    }

    /// Changing to a kind another active goal holds offers to replace that one, as the iOS editor does.
    func testAnotherActiveGoalOfTheKindOffersToReplace() {
        let goal = pastDue()
        let sleep = CoachGoal(kind: .sleep, title: "Sleep 8 h", baseline: 7, target: 8)
        CoachGoalStore.shared.goals = [goal, sleep]
        let s = CoreGoalEditor.run("goals.editor", ["id": goal.id.uuidString,
            "draft": ["kind": "sleep", "title": "Sleep", "baseline": "7", "target": "7.5"]], weightKg: 0)
        XCTAssertEqual(s.limit, "kind")
        XCTAssertEqual(s.replaceId, sleep.id.uuidString)
    }

    func testAMissingGoalIsNotSaved() {
        let s = CoreGoalEditor.run("goals.editor.save", ["id": UUID().uuidString,
            "draft": ["kind": "run", "title": "x", "baseline": "1", "target": "2"]], weightKg: 0)
        XCTAssertFalse(s.found)
        XCTAssertFalse(s.saved)
        XCTAssertTrue(CoachGoalStore.shared.goals.isEmpty)
    }
}
