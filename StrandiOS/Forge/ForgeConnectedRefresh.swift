import SwiftUI
import StrandCore
import StrandDesign

/// "Fetch now" on every tab a connected source feeds: pull down, and each of them is asked.
///
/// The gesture is not new to this app — the Android side has synced the strap on a pull for a long time,
/// and this platform's screen scaffold has carried a `.refreshable` hook for as long. Neither survived
/// the move to the new design, on either phone. This is the Apple half of bringing it back, and it asks
/// the SOURCES rather than the strap alone, because a wearer does not know which of them feeds the card
/// they are looking at.
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
        case failed
    }

    /// One source the gesture can ask: whether it is connected, and what asking it brings back.
    struct Hook {
        let isConnected: @MainActor () -> Bool
        let fetch: @MainActor () async -> Outcome
    }

    var health: Hook?
    var hevy: Hook?
    /// The strap is asked and not awaited: an offload runs for minutes behind its own progress.
    var strap: (isReady: @MainActor () -> Bool, ask: @MainActor () -> Void)?

    /// What the last pull brought, for the few seconds it is worth saying. Held here rather than in a
    /// screen so it survives a tab change, as the Android banner does.
    @Published private(set) var line: String?

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

    /// Whether a pull can do anything at all. A gesture that cannot must not pretend it can.
    var canPull: Bool { !connected.isEmpty }

    func pull() async {
        let now = Int(Date().timeIntervalSince1970)
        let askable = ConnectedSourceRefresh.askable(connected: connected, lastAsked: lastAsked, now: now)
        guard !askable.isEmpty else { return }
        for source in askable { lastAsked[source] = now }

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
        show(ConnectedSourceRefresh.verdict(answers))
    }

    private static func answer(_ source: ConnectedSourceRefresh.Source,
                               _ outcome: Outcome) -> ConnectedSourceRefresh.Answer {
        switch outcome {
        case .brought(let count): return .init(source: source, brought: count)
        case .uncounted: return .init(source: source, brought: nil)
        case .failed: return .init(source: source, brought: 0, failed: true)
        }
    }

    private func show(_ verdict: ConnectedSourceRefresh.Verdict?) {
        // No verdict is a pull that asked nothing but the strap: saying "up to date" would promise what
        // the offload has not delivered yet.
        guard let verdict else { return }
        switch verdict {
        case .upToDate:
            line = String(localized: "Everything is up to date.")
        case .refreshed:
            line = String(localized: "Refreshed.")
        case .brought(let total):
            line = String(localized: "Fetched: \(total) new.")
        case .partial(let failed, let brought):
            let who = failed.map(Self.name(of:)).joined(separator: ", ")
            line = brought > 0
                ? String(localized: "Fetched: \(brought) new. \(who) could not be reached.")
                : String(localized: "\(who) could not be reached, the rest is up to date.")
        }
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.shownFor)
            guard !Task.isCancelled else { return }
            self?.line = nil
        }
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

extension View {
    /// The pull gesture plus the line it leaves behind, for a tab a connected source feeds.
    func forgeRefreshable(_ tab: ForgeRefreshTab) -> some View {
        modifier(ForgeRefreshableModifier(tab: tab))
    }
}

/// `.refreshable`, but only while `active`. Written as its own modifier because applying one inside an
/// `if` changes the view's identity and would reset the scroll position every time a source connects.
private struct RefreshableWhen: ViewModifier {
    let active: Bool
    let action: @Sendable () async -> Void

    func body(content: Content) -> some View {
        content.refreshable {
            guard active else { return }
            await action()
        }
    }
}

private struct ForgeRefreshableModifier: ViewModifier {
    let tab: ForgeRefreshTab
    @ObservedObject private var refresher = ForgeConnectedRefresh.shared

    func body(content: Content) -> some View {
        // `.refreshable` has no "enabled" of its own, so it is applied only while a source could answer.
        // Attached unconditionally it would turn its spinner for a pull that asks nothing — the Android
        // side keeps the gesture off in that case, and a gesture that cannot act must not pretend on
        // either phone.
        content
            .modifier(RefreshableWhen(active: refresher.canPull) { await refresher.pull() })
            .overlay(alignment: .top) {
                if let line = refresher.line {
                    Text(line)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, NoopMetrics.space3)
                        .padding(.vertical, NoopMetrics.space2)
                        .background(StrandPalette.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius,
                                                         style: .continuous))
                        .padding(NoopMetrics.space3)
                        .transition(.opacity)
                }
            }
    }
}
