import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

// Activity-detection reads and writes (fork decision 2026-10-31). The suggestions are what the daily pass
// stored; the answers are wearer input; a confirmed session is a workout row under its own source.
extension Repository {

    /// The stored suggestions of the last two weeks, resolved against the answers, the workouts every source
    /// logged and the spans the old Today card was told to forget.
    func activitySuggestions(settings: ActivitySuggestions.Settings) async -> [ActivitySuggestions.Suggestion] {
        guard let store = await storeHandle() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let from = now - (ActivitySuggestions.listDays + 1) * 86_400
        let candidates = (try? await store.activityCandidates(deviceId: deviceId, from: from, to: now + 1)) ?? []
        guard !candidates.isEmpty else { return [] }
        let answers = (try? await store.activitySuggestionAnswers(from: from, to: now + 1)) ?? []
        let workouts = await workoutRows(days: ActivitySuggestions.listDays + 2)
        return ActivitySuggestions.resolve(candidates: candidates, answers: answers, workouts: workouts,
                                           legacyDismissed: legacyAutoDetectDismissedWindows, settings: settings)
    }

    /// One day's suggestions for the logging sheet: the stored ones when there are any, else computed on
    /// the spot from the stored minutes, so the sheet offers them with detection off too. Read only.
    func activitySuggestions(day: Date, hrMax: Int) async -> [ActivitySuggestions.Suggestion] {
        guard let store = await storeHandle() else { return [] }
        let cal = Calendar.current
        let dayStart = Int(cal.startOfDay(for: day).timeIntervalSince1970)
        let dayEnd = min(Int(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day))!.timeIntervalSince1970),
                         Int(Date().timeIntervalSince1970))
        guard dayEnd > dayStart else { return [] }
        var rows = (try? await store.activityCandidates(deviceId: deviceId, from: dayStart, to: dayEnd)) ?? []
        if rows.isEmpty {
            rows = ((try? await ActivitySuggestions.dayCandidates(
                store: store, deviceId: deviceId, computedId: deviceId + "-noop", hrMax: hrMax,
                dayStart: dayStart, dayEnd: dayEnd)) ?? [])
                .map { ActivitySuggestions.row($0, deviceId: deviceId) }
        }
        let answers = (try? await store.activitySuggestionAnswers(from: dayStart, to: dayEnd)) ?? []
        let workouts = await workoutRows(days: max(2, Int(Date().timeIntervalSince(day) / 86_400) + 2))
        let all = ActivitySuggestions.resolve(candidates: rows, answers: answers, workouts: workouts,
                                              settings: .init(level: .more, walks: true))
        return ActivitySuggestions.forSheet(all, dayStart: dayStart, dayEnd: dayEnd)
    }

    /// Recomputes the recent suggestions now, as the daily pass would, when detection is switched on.
    func refreshActivitySuggestions(hrMax: Int) async {
        guard let store = await storeHandle() else { return }
        _ = try? await ActivitySuggestions.refresh(store: store, deviceId: deviceId, computedId: deviceId + "-noop",
                                                   hrMax: hrMax, now: Int(Date().timeIntervalSince1970))
        await ActivitySuggestionCenter.shared.reload()
    }

    func recordActivityAnswer(_ answer: ActivitySuggestionAnswer) async {
        guard let store = await storeHandle() else { return }
        _ = try? await store.recordActivitySuggestionAnswer(answer)
    }

    /// Writes the confirmed session under `detected-confirmed` (never "manual") and the answer pointing at it.
    func confirmActivitySuggestion(row: WorkoutRow, answer: ActivitySuggestionAnswer) async {
        let confirmed = WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                                   source: WorkoutSource.confirmedSuggestionSource, durationS: row.durationS,
                                   energyKcal: row.energyKcal, avgHr: row.avgHr, maxHr: row.maxHr,
                                   strain: row.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON,
                                   notes: row.notes, steps: row.steps)
        await saveManualWorkout(confirmed)
        var linked = answer
        linked.workout = .init(deviceId: deviceId, startTs: confirmed.startTs, sport: confirmed.sport)
        await recordActivityAnswer(linked)
        await refresh()
    }

    /// Undo: deletes the answer and the confirmed session it saved, if it saved one.
    func undoActivitySuggestion(_ s: ActivitySuggestions.Suggestion) async {
        guard let store = await storeHandle() else { return }
        let track: ActivitySuggestionAnswer.Track = s.track == .walk ? .walk : .heartRate
        let answers = (try? await store.activitySuggestionAnswers(from: s.start, to: s.end)) ?? []
        if let key = answers.first(where: { $0.track == track && $0.candidateStartTs == s.start })?.workout,
           let row = await workoutRows(days: ActivitySuggestions.listDays + 2).first(where: {
               $0.startTs == key.startTs && $0.sport == key.sport
                   && WorkoutSource.classify($0.source) == .confirmed
           }) {
            await deleteWorkout(row)
        }
        _ = try? await store.deleteActivitySuggestionAnswer(track: track, candidateStartTs: s.start)
        await refresh()
    }
}
