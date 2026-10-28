import Foundation
import StrandAnalytics

/// Where the journal's dosed behaviours (alcohol, caffeine) are stored and how a journal question names them.
/// Shared by the Insights hub's dose cards and the coach, outside the SwiftUI screen so the coach links into
/// the Android core.
enum DoseJournal {
    static let doseSource = "noop-journal-dose"

    /// The dose storage key for a behaviour (its raw enum value — the stable, cross-platform key).
    static func doseKey(for behavior: DosedBehavior) -> String { "dose_\(behavior.rawValue)" }

    /// Whether a journal question is the dosed behaviour (so its yes-days back-fill dose = 1).
    static func matches(_ behavior: DosedBehavior, question: String) -> Bool {
        let q = question.lowercased()
        switch behavior {
        case .alcohol:  return q.contains("alcohol") || q.contains("drink")
        case .caffeine: return q.contains("caffeine") || q.contains("coffee")
        }
    }
}
