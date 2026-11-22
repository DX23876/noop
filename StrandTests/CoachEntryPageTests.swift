import XCTest
@testable import Strand

/// Pins the header button's page context (owner, 2026-11-21): the note names the page and its day but no
/// value, and it rides in front of whatever context the turn already had.
final class CoachEntryPageTests: XCTestCase {
    func testNoteNamesPageAndDayButNoValue() {
        let page = CoachEntryPage(kind: .sleep, day: "2026-11-20", suggestions: [])
        XCTAssertTrue(page.promptNote.contains("Sleep page"))
        XCTAssertTrue(page.promptNote.contains("2026-11-20"))
        XCTAssertFalse(page.promptNote.contains(where: { $0 == "%" }))
    }

    func testNoteWithoutDayLeavesTheDayOut() {
        let note = CoachEntryPage(kind: .health, day: nil, suggestions: []).promptNote
        XCTAssertFalse(note.contains(", for "))
    }

    func testContextJoining() {
        let page = CoachEntryPage(kind: .nutrition, day: "2026-11-21", suggestions: [])
        XCTAssertEqual(AICoachEngine.context("data", entryPage: nil), "data")
        XCTAssertEqual(AICoachEngine.context("  ", entryPage: page), page.promptNote)
        XCTAssertEqual(AICoachEngine.context("data", entryPage: page), page.promptNote + "\n\ndata")
    }

    @MainActor
    func testClosingTheChatDropsThePageAndItsChips() {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-coach-entry-page"))
        let page = CoachEntryPage(kind: .sleep, day: "2026-11-20", suggestions: ["Why was my night like this?"])
        engine.openedFromPage(page)
        XCTAssertEqual(engine.entryPage, page)
        XCTAssertEqual(engine.cardSuggestions, page.suggestions)
        engine.clearEntryPage()
        XCTAssertNil(engine.entryPage)
        XCTAssertTrue(engine.cardSuggestions.isEmpty)
    }
}
