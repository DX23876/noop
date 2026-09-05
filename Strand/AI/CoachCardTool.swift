import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - `show_card`: the coach names a card, the app fills it in
//
// The division of labour is the whole design. The model decides that a card would help and says WHICH
// one; every figure on it is resolved here, on device, from the same series the Today screen reads.
//
// The alternative — letting a reply carry the numbers and rendering them — would have been less code
// and strictly worse: a card is read as a measurement, and a measurement assembled by a language model
// from a tool result it summarised is exactly the thing this app refuses to display. It would also let
// a card and the Today screen disagree about the same morning, with nothing to say which was right.

extension AICoachEngine {

    /// Build and queue a card. Returns a text confirmation the reply can refer to, or an honest note
    /// when there is nothing to show — never a card with a fabricated value.
    func handleShowCard(kind rawKind: String, metric: String?, workoutStart: Int?) async -> String {
        switch rawKind.lowercased() {
        case "workout":
            guard let art = await workoutCardArtifact(startTs: workoutStart) else {
                return "No workout to show — check get_recent_workouts for one that exists, and pass its "
                    + "exact start timestamp."
            }
            pendingCards.append(art)
            return "Showed the user a card for \(art.title)."
        default:
            guard let key = metric, let art = await metricCardArtifact(metric: key) else {
                return "No data to show a card for \"\(metric ?? "")\". Say so in words instead."
            }
            pendingCards.append(art)
            return "Showed the user a \(art.title) card reading \(art.value)."
        }
    }

    // MARK: - Metric

    /// A metric card: today's value, how it sits against the user's OWN recent average, and a couple of
    /// supporting figures.
    ///
    /// Resolution goes through the same `chartArtifact` path `plot_metric` uses. That is deliberate:
    /// two resolvers for one metric key is how a card and a chart of the same thing start disagreeing,
    /// and the user would have no way to tell which had drifted.
    func metricCardArtifact(metric: String) async -> CoachCardArtifact? {
        guard let chart = await chartArtifactForCard(metric: metric, days: 30),
              let latest = chart.points.last else { return nil }

        let values = chart.points.map(\.value)
        let format = chart.valueFormat
        // The user's own trailing average — the only comparison NOOP has evidence for. A population
        // "normal range" would be a claim about people in general dressed up as one about this person.
        let mean = values.reduce(0, +) / Double(values.count)
        let delta = latest.value - mean

        var caption: String?
        if values.count >= 7 {
            let direction = abs(delta) < 0.05 * max(abs(mean), 1)
                ? String(localized: "in line with")
                : (delta > 0 ? String(localized: "above") : String(localized: "below"))
            caption = String(localized: "\(direction) your \(values.count)-day average of \(format(mean))")
        }

        var rows: [CoachCardArtifact.Row] = []
        if let hi = values.max(), let lo = values.min(), values.count >= 7 {
            rows.append(.init(label: String(localized: "Range"), value: "\(format(lo)) – \(format(hi))"))
        }
        rows.append(.init(label: String(localized: "Days of data"), value: "\(values.count)"))

        return CoachCardArtifact(kind: .metric, title: chart.title,
                                 value: format(latest.value), caption: caption,
                                 rows: rows, tintName: tintName(for: chart.kind))
    }

    private func tintName(for kind: CoachChartArtifact.Kind) -> String {
        switch kind {
        case .charge: return "charge"
        case .effort: return "effort"
        case .sleep:  return "rest"
        default:      return "accent"
        }
    }

    // MARK: - Workout

    /// A workout card: the session, and what the body did during it.
    ///
    /// A strength session shows what it CONTAINED (sets, volume, RPE) from the Hevy tables; every
    /// session shows the heart rate the strap measured, which is the pairing the whole Hevy lane exists
    /// for. Absent figures are omitted rather than shown as zero — a lifting session with no HR trace
    /// did not have an average heart rate of nothing.
    func workoutCardArtifact(startTs: Int?) async -> CoachCardArtifact? {
        let rows = await repo.workoutRows(days: 365, reconcileHrCap: 30)
        // Nearest by start rather than exact-match: the model is quoting a timestamp back from a tool
        // result, and a minute of drift there should not turn into "no workout found". A tolerance of an
        // hour cannot reach a different session on any realistic day.
        let target = startTs
        let workout: WorkoutRow?
        if let target {
            workout = rows
                .filter { abs($0.startTs - target) <= 3600 }
                .min { abs($0.startTs - target) < abs($1.startTs - target) }
        } else {
            workout = rows.first
        }
        guard let workout else { return nil }

        var detailRows: [CoachCardArtifact.Row] = []
        if let duration = workout.durationS, duration > 0 {
            detailRows.append(.init(label: String(localized: "Duration"),
                                    value: "\(Int(duration / 60)) min"))
        }
        if let avg = workout.avgHr {
            var hr = "\(avg) bpm"
            if let max = workout.maxHr { hr += " · max \(max)" }
            detailRows.append(.init(label: String(localized: "Heart rate"), value: hr))
        }
        if let strain = workout.strain {
            detailRows.append(.init(label: String(localized: "Effort"),
                                    value: String(format: "%.1f", strain)))
        }

        // The strength half, when there is one: what was actually lifted.
        var headline = WorkoutSource.displaySport(workout.sport)
        if let store = await repo.storeHandle(),
           let session = (try? await store.hevyWorkouts(from: workout.startTs - 3600,
                                                        to: workout.startTs + 3600, limit: 5))?
            .min(by: { abs($0.startTs - workout.startTs) < abs($1.startTs - workout.startTs) }) {
            let templates = (try? await store.hevyExerciseTemplates()) ?? [:]
            let summary = StrengthSession.summarize(session, templates: templates)
            if !session.title.isEmpty { headline = session.title }
            detailRows.insert(.init(label: String(localized: "Working sets"),
                                    value: "\(summary.workingSetCount) · \(summary.exerciseCount) exercises"),
                              at: 0)
            if summary.volumeLoadKg > 0 {
                detailRows.insert(.init(label: String(localized: "Volume"),
                                        value: "\(HevySource.groupedKg(summary.volumeLoadKg)) kg"),
                                  at: 1)
            }
            if let rpe = summary.meanRpe {
                detailRows.append(.init(label: String(localized: "RPE"),
                                        value: String(format: "%.1f", rpe)
                                            + " (\(summary.rpeSetCount)/\(summary.workingSetCount))"))
            }
        }

        let when = Date(timeIntervalSince1970: TimeInterval(workout.startTs))
            .formatted(date: .abbreviated, time: .shortened)
        return CoachCardArtifact(kind: .workout, title: headline, value: when, caption: nil,
                                 rows: Array(detailRows.prefix(4)), tintName: "effort")
    }
}
