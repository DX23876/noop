import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Activity detection for Android (fork decision 2026-10-31): the same suggestions, the same resolver and the
/// same answer table the Apple app uses, so Today's prompt, the inbox and the notifications on both platforms
/// read one state. Android's daily pass does not keep the switch, so the list call refreshes the recent days
/// itself while detection is on.
enum CoreActivity {
    struct Item: Encodable {
        var id: String
        var track: String
        var start: Int
        var end: Int
        var avgBpm: Int?
        var load: Double
        var kinds: [String]
        /// open, logged, or the answer: sport, walk, everyday, housework.
        var state: String
        var asks: Bool
    }

    struct Output: Encodable {
        var toAsk: [Item]
        var inbox: [Item]
        /// The words the Apple app shows, from the same catalog, so both platforms say the same thing. The
        /// span lines are formats with two `%@` times and one `%lld` minute count (`%1$@`… in some languages).
        var labels: [String: String]
    }

    static let words: [String: String] = [
        "walkTitle": "Walk detected", "activityTitle": "Activity detected", "saveWalk": "Save as walk",
        "saveAs": "Save as %@", "otherKind": "Other kind…", "notTraining": "Not training", "housework": "Housework",
        "later": "Later", "more": "%lld more", "section": "Detected activities", "answer": "Answer", "undo": "Undo",
        "logged": "Already in your workouts", "savedWalk": "Saved as walk", "savedTraining": "Saved as training",
        "spanToday": "Today from %@ to %@. About %lld minutes.",
        "spanYesterday": "Yesterday from %@ to %@. About %lld minutes.",
        "spanDay": "%@ from %@ to %@. About %lld minutes.", "avg": "avg %lld bpm", "min": "min",
        "whenToday": "Today, %@ to %@", "whenYesterday": "Yesterday, %@ to %@", "whenDay": "%@, %@ to %@",
        "kind.walk": "Walk", "kind.run": "sport.running", "kind.cycle": "Cycling", "kind.strength": "Strength",
        "kind.other": "Other", "adjust": "Adjust",
    ]

    static func settings(_ args: [String: Any]) -> ActivitySuggestions.Settings {
        .init(level: (args["level"] as? String).flatMap(ActivityCandidates.Level.init(rawValue:)) ?? .balanced,
              walks: args["walks"] as? Bool ?? true)
    }

    static func list(reader: StoreReader, args: [String: Any], now: Int = Int(Date().timeIntervalSince1970)) async -> Output {
        let id = reader.activeDeviceId
        if let hrMax = (args["maxHR"] as? NSNumber)?.intValue {
            _ = try? await ActivitySuggestions.refresh(store: reader.store, deviceId: id, computedId: id + "-noop",
                                                       hrMax: hrMax, now: now)
        }
        let all = await resolved(reader: reader, settings: settings(args),
                                 legacy: WorkoutSource.dismissedWindows(args["dismissed"] as? [String] ?? []), now: now)
        let snoozed = Set(args["snoozed"] as? [String] ?? [])
        var labels = words.mapValues { $0.localizedCatalogValue }
        if labels["kind.run"] == "sport.running" { labels["kind.run"] = "Running" }
        return Output(toAsk: ActivitySuggestions.toAsk(all, now: now, snoozed: snoozed).map(item),
                      inbox: ActivitySuggestions.inbox(all, now: now).map(item), labels: labels)
    }

    static func resolved(reader: StoreReader, settings: ActivitySuggestions.Settings, legacy: [Range<Int>],
                         now: Int) async -> [ActivitySuggestions.Suggestion] {
        let from = now - (ActivitySuggestions.listDays + 1) * 86_400
        let candidates = (try? await reader.store.activityCandidates(deviceId: reader.activeDeviceId, from: from,
                                                                     to: now + 1)) ?? []
        let answers = (try? await reader.store.activitySuggestionAnswers(from: from, to: now + 1)) ?? []
        let workouts = await reader.rawWorkoutRows(from: from - 86_400, to: now + 86_400, dismissedDetectedSpans: [])
        return ActivitySuggestions.resolve(candidates: candidates, answers: answers, workouts: workouts,
                                           legacyDismissed: legacy, settings: settings)
    }

    /// "answer" is everyday or housework (an answer row only), or sport/walk with `sport`, `start` and `end`
    /// (the session as the wearer saved it), which writes the confirmed workout row first.
    static func answer(reader: StoreReader, args: [String: Any], now: Int = Int(Date().timeIntervalSince1970)) async -> Bool {
        guard let id = args["id"] as? String,
              let raw = args["answer"] as? String, let answer = ActivitySuggestionAnswer.Answer(rawValue: raw),
              let origin = (args["origin"] as? String).flatMap(ActivitySuggestionAnswer.Origin.init(rawValue:)),
              let s = await resolved(reader: reader, settings: .init(level: .more, walks: true), legacy: [], now: now)
                .first(where: { $0.id == id }) else { return false }
        var workout: ActivitySuggestionAnswer.WorkoutKey?
        var sport: String?
        if answer == .sport || answer == .walk {
            let start = (args["start"] as? NSNumber)?.intValue ?? s.start
            let end = (args["end"] as? NSNumber)?.intValue ?? s.end
            let name = (args["sport"] as? String) ?? (answer == .walk ? "Walking" : "Workout")
            guard end > start else { return false }
            let row = WorkoutRow(startTs: start, endTs: end, sport: name, source: WorkoutSource.confirmedSuggestionSource,
                                 durationS: Double(end - start), energyKcal: nil, avgHr: s.avgBpm, maxHr: nil,
                                 strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
            guard (try? await reader.store.upsertWorkouts([row], deviceId: reader.activeDeviceId)) != nil else { return false }
            workout = .init(deviceId: reader.activeDeviceId, startTs: start, sport: name)
            sport = answer == .sport ? name : nil
        }
        let shownAt = (args["shownAt"] as? NSNumber)?.intValue
        let row = ActivitySuggestions.answer(s, answer, sport: sport, origin: origin, shownAt: shownAt, now: now,
                                             workout: workout)
        return (try? await reader.store.recordActivitySuggestionAnswer(row)) ?? false
    }

    /// Undo: the answer goes, and so does the confirmed session it saved.
    static func undo(reader: StoreReader, args: [String: Any]) async -> Bool {
        guard let track = (args["track"] as? String).flatMap(ActivitySuggestionAnswer.Track.init(rawValue:)),
              let start = (args["start"] as? NSNumber)?.intValue else { return false }
        let end = (args["end"] as? NSNumber)?.intValue ?? start + 1
        let answers = (try? await reader.store.activitySuggestionAnswers(from: start, to: end)) ?? []
        if let key = answers.first(where: { $0.track == track && $0.candidateStartTs == start })?.workout {
            _ = try? await reader.store.deleteWorkouts(deviceId: key.deviceId, sport: key.sport,
                                                       from: key.startTs, to: key.startTs)
        }
        return (try? await reader.store.deleteActivitySuggestionAnswer(track: track, candidateStartTs: start)) ?? false
    }

    static func item(_ s: ActivitySuggestions.Suggestion) -> Item {
        let state: String
        switch s.state {
        case .open: state = "open"
        case .logged: state = "logged"
        case .answered(let a): state = a.rawValue
        }
        return Item(id: s.id, track: s.track.rawValue, start: s.start, end: s.end, avgBpm: s.avgBpm, load: s.load,
                    kinds: s.kinds.map(\.rawValue), state: state, asks: s.asks)
    }
}
