import SwiftUI
import UIKit
import StrandCore
import StrandDesign

/// "Fetch now" on every tab a connected source feeds: pull down, and each of them is asked.
///
/// The gesture is not new to this app — the classic Today screen has synced the strap on a pull for a
/// long time. What the new design lost is not the gesture on this phone but its MEANING: all four Forge
/// tabs still pull, and all four only re-read the store, so the spinner turned and nothing was fetched.
/// (That is also why this is wired into each tab's existing `.refreshable` rather than added above it:
/// an outer one never fires, the inner gesture wins, and five pulls on the owner's iPhone proved it.)
/// So a pull asks the SOURCES, not the store and not the strap alone, because a wearer does not know
/// which of them feeds the card they are looking at.
///
/// Who may be asked, how often, and what the one line says is `ConnectedSourceRefresh` in the shared
/// core, so this phone and the other cannot come to different conclusions about the same pull. What is
/// this side's is the wording and the wiring: the sources are closures, set once by the app scene, for
/// the same reason `AppModel.healthWriteBack` is one — HealthKit and the strap live in iOS-only types
/// this view layer should not reach into.
enum ForgeRefreshTab: String, CaseIterable, Sendable {
    case today
    case training
    case sleep
    case health
}

@MainActor
final class ForgeConnectedRefresh: ObservableObject {
    static let shared = ForgeConnectedRefresh()

    /// What asking a source brought back. Three answers, not two: an importer that ran and cannot count
    /// what it fetched (HealthKit answers true or false and nothing else) must not be folded into either
    /// "brought nothing" or "could not be reached" — both would be a claim it never made.
    enum Outcome {
        case brought(Int)
        case uncounted
        /// The source cannot be used at all right now — no key, no permission, nothing to reach. It is
        /// left OUT of the verdict rather than named as a failure: telling a wearer that Hevy could not
        /// be reached when they never set it up is a complaint about a service they do not use
        /// (owner, 2026-11-22).
        case notAvailable
        case failed
    }

    /// One source the gesture can ask: whether it is connected, and what asking it brings back.
    ///
    /// `settle` is for a source whose own state is not known yet when a screen appears. HealthKit's is
    /// not: the bridge starts at `.unknown` and only resolves once the launch pipeline has asked the
    /// daemon, which is AFTER a wearer can already have pulled. Without it a pull right after a relaunch
    /// finds Apple Health "not connected", asks nobody but the strap, and says nothing at all — which is
    /// what happened on the owner's iPhone (2026-11-22).
    struct Hook {
        let isConnected: @MainActor () -> Bool
        let fetch: @MainActor () async -> Outcome
        var settle: (@MainActor () async -> Void)?
    }

    var health: Hook?
    var hevy: Hook?
    /// The strap is asked and not awaited: an offload runs for minutes behind its own progress.
    var strap: (isReady: @MainActor () -> Bool, ask: @MainActor () -> Void)?

    /// One line per pull for the strap log, always on. A pull is a handful of taps a day, so the line
    /// costs nothing, and its absence is what turned one wrong source check into an evening of guessing
    /// (2026-11-22): the Android side had its line and was provable in seconds.
    var log: (@MainActor (String) -> Void)?

    /// What a source said when it declined. The verdict line names WHICH source the pull could not use;
    /// this names WHY, and it is the half whose absence cost an evening: three pulls in a row reported
    /// Apple Health and Hevy as unreachable, and nothing anywhere said that the first was a pass already
    /// running and the second a key the service itself had rejected. A line that can only be read as
    /// "could not be reached" is a diagnostic asserting more than it observed (AGENTS.md).
    func note(_ source: ConnectedSourceRefresh.Source, declined reason: String) {
        log?("Pull: \(source.rawValue) declined — \(reason)")
    }

    /// What the last pull brought, for the few seconds it is worth saying. Held here rather than in a
    /// screen so it survives a tab change, as the Android banner does.
    @Published private(set) var line: String?

    /// True while a pull is still asking. The system's own spinner says a gesture was made; this says
    /// the app is doing something about it, which is the half the Android import banner carries there.
    @Published private(set) var fetching = false

    /// When each source was last asked, so the core's floor can hold off a drumbeat of pulls.
    private var lastAsked: [ConnectedSourceRefresh.Source: Int] = [:]
    private var fadeTask: Task<Void, Never>?

    /// How long the line stands before it fades. The Android side holds it for the same three seconds.
    private static let shownFor: Duration = .seconds(3)

    private var connected: Set<ConnectedSourceRefresh.Source> {
        var found: Set<ConnectedSourceRefresh.Source> = []
        if health?.isConnected() == true { found.insert(.health) }
        if hevy?.isConnected() == true { found.insert(.hevy) }
        if strap?.isReady() == true { found.insert(.strap) }
        return found
    }

    private func settleAll() async {
        await health?.settle?()
        await hevy?.settle?()
    }

    func pull() async {
        // A pull can arrive before the launch pipeline has resolved a source's state; ask it to settle
        // first, so "nothing is connected" is a fact rather than a race.
        await settleAll()
        let now = Int(Date().timeIntervalSince1970)
        let askable = ConnectedSourceRefresh.askable(connected: connected, lastAsked: lastAsked, now: now)
        let names = { (set: Set<ConnectedSourceRefresh.Source>) in
            set.map(\.rawValue).sorted().joined(separator: ",")
        }
        guard !askable.isEmpty else {
            log?("Pull: connected \(names(connected).isEmpty ? "none" : names(connected)) — asked none")
            // Said, not swallowed: a pull that cannot reach anything is the one case where silence
            // reads exactly like a broken gesture.
            if connected.isEmpty { setLine(String(localized: "No source is connected.")) }
            return
        }
        for source in askable { lastAsked[source] = now }
        fetching = true
        defer { fetching = false }

        var answers: [ConnectedSourceRefresh.Answer] = []
        // Asked side by side: Hevy should not wait behind a month of Health.
        await withTaskGroup(of: ConnectedSourceRefresh.Answer?.self) { group in
            for source in askable {
                switch source {
                case .health:
                    if let hook = health {
                        group.addTask { @MainActor in Self.answer(.health, await hook.fetch()) }
                    }
                case .hevy:
                    if let hook = hevy {
                        group.addTask { @MainActor in Self.answer(.hevy, await hook.fetch()) }
                    }
                case .strap:
                    strap?.ask()
                    group.addTask { .init(source: .strap) }
                }
            }
            for await answer in group { if let answer { answers.append(answer) } }
        }
        let verdict = ConnectedSourceRefresh.verdict(answers)
        log?("Pull: asked \(names(askable)) — \(Self.describe(verdict))")
        show(verdict)
    }

    private static func describe(_ verdict: ConnectedSourceRefresh.Verdict?) -> String {
        switch verdict {
        case nil: return "nothing to say"
        case .upToDate: return "up to date"
        case .refreshed: return "refreshed"
        case .strapAsked: return "strap asked"
        case .brought(let total): return "brought \(total)"
        case .partial(let failed, let brought):
            return "partial, failed \(failed.map(\.rawValue).joined(separator: ",")), brought \(brought)"
        }
    }

    private static func answer(_ source: ConnectedSourceRefresh.Source,
                               _ outcome: Outcome) -> ConnectedSourceRefresh.Answer? {
        switch outcome {
        case .brought(let count): return .init(source: source, brought: count)
        case .uncounted: return .init(source: source, brought: nil)
        case .notAvailable: return nil
        case .failed: return .init(source: source, brought: 0, failed: true)
        }
    }

    /// Puts a line up for its few seconds and takes it down again.
    private func setLine(_ text: String) {
        line = text
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.shownFor)
            guard !Task.isCancelled else { return }
            self?.line = nil
        }
    }

    private func show(_ verdict: ConnectedSourceRefresh.Verdict?) {
        // No verdict is a pull that asked nothing but the strap: saying "up to date" would promise what
        // the offload has not delivered yet.
        guard let verdict else { return }
        var line: String?
        switch verdict {
        case .upToDate:
            line = String(localized: "Everything is up to date.")
        case .refreshed:
            line = String(localized: "Refreshed.")
        case .strapAsked:
            line = String(localized: "Syncing the strap…")
        case .brought(let total):
            line = String(localized: "Fetched: \(total) new.")
        case .partial(let failed, let brought):
            let who = failed.map(Self.name(of:)).joined(separator: ", ")
            line = brought > 0
                ? String(localized: "Fetched: \(brought) new. \(who) could not be reached.")
                : String(localized: "\(who) could not be reached, the rest is up to date.")
        }
        if let line { setLine(line) }
    }

    /// A source as the wearer knows it. Product names stay as they are; the strap never reaches this line.
    private static func name(of source: ConnectedSourceRefresh.Source) -> String {
        switch source {
        case .health: return "Apple Health"
        case .hevy: return "Hevy"
        case .strap: return "Strap"
        }
    }
}

/// The strips the pull leaves behind, for a tab that already carries `.refreshable`.
///
/// The gesture itself is NOT added here: every Forge tab has had one since the rebuild, calling
/// `repo.refresh()`. A second `.refreshable` on the outside never fires — the inner one takes the pull —
/// which is why five pulls on the owner's iPhone did nothing and wrote nothing (2026-11-22). What was
/// missing was never the gesture; it was that the gesture only re-read the store instead of asking the
/// sources. So the tabs call `pull()` from the gesture they already had, and this draws what it said.
struct ForgeRefreshStrips: View {
    @ObservedObject private var refresher = ForgeConnectedRefresh.shared

    var body: some View {
        VStack(spacing: NoopMetrics.space2) {
            if refresher.fetching { strip(String(localized: "Fetching…")) }
            if let line = refresher.line { strip(line) }
        }
    }

    private func strip(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, NoopMetrics.space3)
            .padding(.vertical, NoopMetrics.space2)
            .background(StrandPalette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            .padding(NoopMetrics.space3)
            .transition(.opacity)
    }
}
