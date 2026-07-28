import XCTest
import WhoopStore
@testable import Strand

final class CoachJournalPatternAnalyzerTests: XCTestCase {
    func testExplicitNoIsControlAndMissingDaysAreExcluded() {
        var entries: [JournalEntry] = []
        var outcomes: [String: Double] = [:]
        for day in 1...10 {
            let key = String(format: "2026-07-%02d", day)
            entries.append(JournalEntry(day: key, question: "Late caffeine",
                                        answeredYes: true, notes: nil))
            outcomes[key] = 40 + Double(day % 2)
        }
        for day in 11...20 {
            let key = String(format: "2026-07-%02d", day)
            entries.append(JournalEntry(day: key, question: "Late caffeine",
                                        answeredYes: false, notes: nil))
            outcomes[key] = 80 + Double(day % 2)
        }
        // These have outcomes but no answer for the question. Treating missing as No would change n.
        for day in 21...27 {
            outcomes[String(format: "2026-07-%02d", day)] = 5
        }

        let evidence = CoachJournalPatternAnalyzer.analyze(
            entries: entries,
            outcomeByDay: outcomes,
            outcomeName: "Charge",
            now: date("2026-07-28")
        )

        XCTAssertFalse(evidence.isEmpty)
        XCTAssertTrue(evidence.allSatisfy { $0.sampleCount == 20 })
        XCTAssertTrue(evidence.allSatisfy { $0.sentence.contains("association, not proof") })
    }

    func testMissingIsNotSilentlyConvertedToNo() {
        let entries = (1...10).map {
            JournalEntry(day: String(format: "2026-07-%02d", $0),
                         question: "Meditated", answeredYes: true, notes: nil)
        }
        let outcomes = Dictionary(uniqueKeysWithValues: (1...20).map {
            (String(format: "2026-07-%02d", $0), Double($0))
        })

        XCTAssertTrue(CoachJournalPatternAnalyzer.analyze(
            entries: entries,
            outcomeByDay: outcomes,
            outcomeName: "Charge",
            now: date("2026-07-28")
        ).isEmpty)
    }

    private func date(_ day: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)!
    }
}
