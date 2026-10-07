import WidgetKit
import SwiftUI

/// One moment of the fitness widgets: the app's last payload (nil before the first publish).
struct FitnessEntry: TimelineEntry {
    let date: Date
    let snapshot: FitnessWidgetSnapshot?

    /// The payload's numbers belong to an earlier day than the one the widget is drawing on.
    var isStale: Bool {
        guard let snapshot else { return false }
        return !Calendar.current.isDate(snapshot.updated, inSameDayAs: date)
    }
}

/// The one provider all ten fitness widgets share. The app reloads them whenever it publishes new
/// numbers; a second entry at midnight lets each widget mark yesterday's numbers as such even when the
/// app stays closed.
struct FitnessProvider: TimelineProvider {
    func placeholder(in context: Context) -> FitnessEntry {
        FitnessEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FitnessEntry) -> Void) {
        completion(FitnessEntry(date: Date(),
                                snapshot: FitnessWidgetSnapshot.load() ?? (context.isPreview ? .placeholder : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FitnessEntry>) -> Void) {
        let now = Date()
        let snapshot = FitnessWidgetSnapshot.load()
        var entries = [FitnessEntry(date: now, snapshot: snapshot)]
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        entries.append(FitnessEntry(date: midnight, snapshot: snapshot))
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(86_400))))
    }
}
