import Foundation
import Combine
import StrandAnalytics
import StrandCore
import WhoopStore

/// The app side of activity detection (fork decision 2026-10-31): the one shared state the Today prompt, the
/// inbox rows, the logging sheet and the notifications read, resolved through `ActivitySuggestions` in the
/// core. Every answer goes through here, so it lands in the answer table once and every surface sees it.
@MainActor
final class ActivitySuggestionCenter: ObservableObject {
    static let shared = ActivitySuggestionCenter()

    /// Every stored suggestion of the last two weeks with its state.
    @Published private(set) var all: [ActivitySuggestions.Suggestion] = []
    /// Suggestions put off with "Later" in this launch. Writes nothing: a later launch asks again.
    @Published private(set) var snoozed: Set<String> = []
    /// A suggestion to open on the logging sheet (a notification tap, "Other kind" on the prompt, an inbox
    /// row). `ActivitySuggestionSheetHost` presents it wherever the app is.
    struct OpenRequest: Identifiable {
        let suggestion: ActivitySuggestions.Suggestion
        let origin: ActivitySuggestionAnswer.Origin
        var id: String { suggestion.id }
    }
    @Published var openRequest: OpenRequest?
    /// When each suggestion was first shown, for the answer delay.
    private var shownAt: [String: Int] = [:]

    private weak var repo: Repository?
    private var refreshWatch: AnyCancellable?
    private var loading = false
    /// A reload asked for while one runs; it runs once more after, so a write in between is never missed.
    private var reloadAgain = false

    private init() {}

    /// Wires the center to the app's repository once; every data refresh re-reads the suggestions.
    func attach(_ repo: Repository) {
        guard self.repo !== repo else { return }
        self.repo = repo
        refreshWatch = repo.$refreshSeq.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: ActivitySuggestions.enabledKey) }

    nonisolated static var settings: ActivitySuggestions.Settings {
        let d = UserDefaults.standard
        let level = d.string(forKey: ActivitySuggestions.levelKey).flatMap(ActivityCandidates.Level.init(rawValue:))
        return .init(level: level ?? .balanced, walks: d.object(forKey: ActivitySuggestions.walksKey) as? Bool ?? true)
    }

    var now: Int { Int(Date().timeIntervalSince1970) }

    /// What Today asks about, newest first.
    var toAsk: [ActivitySuggestions.Suggestion] {
        Self.isEnabled ? ActivitySuggestions.toAsk(all, now: now, snoozed: snoozed) : []
    }

    /// The inbox rows of the last two weeks.
    var inbox: [ActivitySuggestions.Suggestion] {
        Self.isEnabled ? ActivitySuggestions.inbox(all, now: now) : []
    }

    func reload() async {
        guard let repo else { return }
        guard !loading else {
            reloadAgain = true
            return
        }
        guard Self.isEnabled else {
            all = []
            return
        }
        loading = true
        defer { loading = false }
        repeat {
            reloadAgain = false
            all = await repo.activitySuggestions(settings: Self.settings)
        } while reloadAgain
        ActivitySuggestionNotifier.update(with: toAsk, now: now)
    }

    func snooze(_ s: ActivitySuggestions.Suggestion) { snoozed.insert(s.id) }

    func markShown(_ s: ActivitySuggestions.Suggestion) {
        if shownAt[s.id] == nil { shownAt[s.id] = now }
    }

    /// "Not training" or "Housework": an answer row only, never a workout.
    func answer(_ s: ActivitySuggestions.Suggestion, _ answer: ActivitySuggestionAnswer.Answer,
                origin: ActivitySuggestionAnswer.Origin) async {
        guard let repo else { return }
        await repo.recordActivityAnswer(ActivitySuggestions.answer(
            s, answer, sport: nil, origin: origin, shownAt: shownAt[s.id], now: now, workout: nil))
        ActivitySuggestionNotifier.answered(s.id)
        await reload()
    }

    /// Saves the session the wearer confirmed (straight from the prompt, or from the logging sheet after
    /// they adjusted it) under the confirmed-suggestion source, and the answer that points at it.
    func confirm(_ s: ActivitySuggestions.Suggestion, row: WorkoutRow, origin: ActivitySuggestionAnswer.Origin) async {
        guard let repo else { return }
        let kind = ActivityDetectionScore.Kind.of(sport: row.sport)
        let answer: ActivitySuggestionAnswer.Answer = kind == .walk ? .walk : .sport
        await repo.confirmActivitySuggestion(row: row, answer: ActivitySuggestions.answer(
            s, answer, sport: answer == .sport ? row.sport : nil, origin: origin, shownAt: shownAt[s.id],
            now: now, workout: nil))
        ActivitySuggestionNotifier.answered(s.id)
        await reload()
    }

    /// A session logged by hand (the sheet from the menu, a live session) over an open suggestion answers
    /// it, so learning sees the answer and the inbox shows it as logged. A confirmation records its own.
    func noteLogged(_ row: WorkoutRow) async {
        guard let repo, Self.isEnabled, WorkoutSource.classify(row.source) != .confirmed else { return }
        let span = ActivityDetectionScore.Span(start: row.startTs, end: row.endTs)
        guard let s = all.first(where: {
            $0.state == .open
                && ActivityDetectionScore.iou(span, .init(start: $0.start, end: $0.end)) >= ActivityDetectionScore.minimumIoU
        }) else { return }
        let kind = ActivityDetectionScore.Kind.of(sport: row.sport)
        await repo.recordActivityAnswer(ActivitySuggestions.answer(
            s, kind == .walk ? .walk : .sport, sport: kind == .walk ? nil : row.sport, origin: .sheet,
            shownAt: shownAt[s.id], now: now,
            workout: .init(deviceId: repo.deviceId, startTs: row.startTs, sport: row.sport)))
        ActivitySuggestionNotifier.answered(s.id)
    }

    /// Undo from the inbox: the suggestion is open again, and a session it saved is removed.
    func undo(_ s: ActivitySuggestions.Suggestion) async {
        guard let repo else { return }
        await repo.undoActivitySuggestion(s)
        await reload()
    }

    /// The row the logging sheet opens with for a suggestion: its span and its most likely kind.
    nonisolated static func prefill(_ s: ActivitySuggestions.Suggestion, kind: ActivityDetectionScore.Kind? = nil) -> WorkoutRow {
        WorkoutRow(startTs: s.start, endTs: s.end, sport: sportToken(kind ?? s.likelyKind), source: "manual",
                   durationS: Double(s.end - s.start), energyKcal: nil, avgHr: s.avgBpm, maxHr: nil, strain: nil,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    /// The stored sport a kind is saved as: locale-stable, the spelling the rest of the app already reads.
    nonisolated static func sportToken(_ kind: ActivityDetectionScore.Kind) -> String {
        switch kind {
        case .walk: return "Walking"
        case .run: return "Running"
        case .cycle: return "Cycling"
        case .strength: return "Strength Training"
        case .other: return "Workout"
        }
    }

    /// The kind in the wearer's language.
    nonisolated static func kindName(_ kind: ActivityDetectionScore.Kind) -> String {
        switch kind {
        case .walk: return String(localized: "Walk")
        case .run: return String(localized: "sport.running", defaultValue: "Running")
        case .cycle: return String(localized: "Cycling")
        case .strength: return String(localized: "Strength")
        case .other: return String(localized: "Other")
        }
    }
}
