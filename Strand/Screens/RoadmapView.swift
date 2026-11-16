import SwiftUI
import StrandCore
import StrandDesign

// RoadmapView.swift — the Roadmap page and the pieces the four project pages share.
//
// Two static files from the repository (`docs/roadmap.json`, `docs/app-feed.json`) are read when this
// screen opens, and at no other time: no background poll, no account, nothing about the reader sent.
// The whole reading, clamping and grouping lives in `StrandCore.ProjectPageStore`, so the Android twin
// shows the same words from the same bytes.
//
// Deliberately quiet: no badge on the Settings row, no bell, no unread dot, no "new" markers, no
// ranking of reported problems. Someone who never opens this page never notices it exists.

/// The screen's state. Shows the cached copy at once, then refreshes in the background, so opening the
/// page is never a spinner on a plain canvas.
@MainActor
final class RoadmapModel: ObservableObject {
    @Published var page: ProjectPage = .empty
    @Published var isRefreshing = false
    /// True once a read has been attempted, so "nothing here" is only said after actually looking.
    @Published var hasLoaded = false
    /// This device's own thumbs, from preferences: the screen must know them with no network.
    @Published var myVotes: Set<String> = []
    /// Totals, asked for only once this device has voted at all — a number before that would steer the
    /// vote, and an untouched page makes no request.
    @Published var counts: [String: Int] = [:]
    @Published var draft = ""
    @Published var isSending = false
    @Published var sentConfirmation = false
    @Published var sendFailed = false
    /// The wish whose thumb did not go out, if any. Without it a refused vote was a thumb that simply
    /// did not move: indistinguishable from a tap the screen never received.
    @Published var voteFailed: String?

    private let store: ProjectPageStore
    private let keys: ProjectDeviceKeyStore
    private var service: ProjectService?

    init(store: ProjectPageStore? = nil, keys: ProjectDeviceKeyStore = .standard) {
        self.store = store ?? ProjectPageStore(directory: RoadmapModel.cacheDirectory)
        self.keys = keys
    }

    /// True only when the feed carries a service address. No address, no voting and no suggestion field:
    /// an installed copy from before the service existed stays quiet instead of failing at a dead URL.
    var canWrite: Bool { page.service != nil }

    func vote(_ suggestion: ProjectSuggestion) async {
        guard let service else { return }
        let wants = !myVotes.contains(suggestion.id)
        voteFailed = nil
        let result = await service.vote(id: suggestion.id, on: wants)
        guard case .sent(let count) = result else {
            voteFailed = suggestion.id
            return
        }
        myVotes = keys.votedItems()
        if let count { counts[suggestion.id] = count }
    }

    func send() async {
        guard let service, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true
        sendFailed = false
        let result = await service.suggest(text: draft)
        isSending = false
        if case .sent = result {
            draft = ""
            sentConfirmation = true
        } else {
            sendFailed = true
        }
    }

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ProjectPage", isDirectory: true)
    }

    func load() async {
        if page.isEmpty {
            page = await store.cached()
        }
        await refresh()
    }

    func refresh() async {
        isRefreshing = true
        let fresh = await store.refresh()
        page = fresh
        myVotes = keys.votedItems()
        service = ProjectService(service: fresh.service, keyStore: keys)
        if let service, !myVotes.isEmpty {
            counts = await service.counts()
        }
        hasLoaded = true
        isRefreshing = false
    }
}

/// The plan: what is being built now, what comes next, what is further out. Nothing else. Opened from
/// `ProjectHubView`, which owns the model and does the one read.
struct RoadmapView: View {
    @ObservedObject var model: RoadmapModel

    var body: some View {
        ScreenScaffold(
            title: "Roadmap",
            subtitle: "What is being built, and what comes after",
            onRefresh: { await model.refresh() }
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ProjectScene(name: "scene_roadmap")
                phaseSection(.now, title: "In progress", icon: "hammer.fill")
                phaseSection(.next, title: "Next", icon: "arrow.forward.circle.fill")
                phaseSection(.later, title: "Later", icon: "clock.fill")
                emptyNote
            }
        }
    }

    /// Said only after a read actually happened, so an empty page is never mistaken for an empty plan.
    @ViewBuilder
    private var emptyNote: some View {
        if model.hasLoaded && model.page.items(.now).isEmpty && model.page.items(.next).isEmpty
            && model.page.items(.later).isEmpty {
            ForgeListGroup("Nothing listed") {
                Text("The plan could not be read, or there is none right now.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func phaseSection(_ phase: ProjectPhase, title: LocalizedStringKey,
                              icon: String) -> some View {
        let items = model.page.items(phase)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                RoadmapSectionHeader(title: title, icon: icon)
                ForEach(items) { item in
                    RoadmapCard(item: item)
                }
            }
        }
    }
}

/// A section heading with its own symbol. The slot is where the drawn section pictures go once they
/// exist; until then it is a tinted symbol rather than a placeholder box.
struct RoadmapSectionHeader: View {
    let title: LocalizedStringKey
    let icon: String

    var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: icon)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// One planned piece of work. Tinted from its measure, never from a colour of its own, so the page
/// stays inside the wearer's chosen profile instead of turning into a rainbow.
struct RoadmapCard: View {
    let item: ProjectRoadmapItem

    var body: some View {
        NoopCard(padding: NoopMetrics.space3) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: item.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(RoadmapCard.tint(item.area))
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.line.isEmpty {
                        Text(item.line)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let since = RoadmapCard.sinceText(item.since) {
                        Text("Started \(since)")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    static func tint(_ area: ProjectArea) -> Color {
        switch area {
        case .sleep: return StrandPalette.restColor
        case .cardio: return StrandPalette.cardioColor
        case .strength: return StrandPalette.strengthColor
        case .body: return StrandPalette.metricCyan
        case .app: return StrandPalette.accent
        }
    }

    /// `yyyy-MM-dd` from the file, rendered in the reader's locale. Nil when the file has no date or
    /// one this app cannot read, because a half-parsed date is worse than none.
    static func sinceText(_ raw: String?) -> String? {
        guard let raw, let date = RoadmapDates.day(raw) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// One suggestion somebody sent in, with the owner's answer and this device's thumb.
///
/// The count appears only after you voted: a number beside an unvoted card steers the vote, which is the
/// opposite of what it is for. There is no ranking badge and no "top" marker for the same reason.
struct SuggestionCard: View {
    let suggestion: ProjectSuggestion
    let voted: Bool
    let count: Int?
    let canVote: Bool
    /// True when this card's own thumb was refused. One card at a time: the model remembers the last
    /// one, because a line under every card would outlive the attempt it belongs to.
    var failed = false
    let toggle: () -> Void

    var body: some View {
        NoopCard(padding: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 6) {
                Text(suggestion.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !suggestion.detail.isEmpty {
                    Text(suggestion.detail)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reply = suggestion.reply {
                    Text(reply)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.leading, NoopMetrics.space2)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(StrandPalette.accent).frame(width: 2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: NoopMetrics.space2) {
                    if let status = SuggestionCard.statusText(suggestion) {
                        Text(status)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if canVote {
                        Button(action: toggle) {
                            HStack(spacing: 4) {
                                Image(systemName: voted ? "hand.thumbsup.fill" : "hand.thumbsup")
                                if let count, voted {
                                    Text("\(count)").font(StrandFont.caption)
                                }
                            }
                            .font(StrandFont.subhead)
                            .foregroundStyle(voted ? StrandPalette.accent : StrandPalette.textSecondary)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(voted ? Text("Remove your vote") : Text("Vote for this"))
                    }
                }
                if failed {
                    Text("That did not go out. Try again later.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    static func statusText(_ suggestion: ProjectSuggestion) -> String? {
        if suggestion.roadmapID != nil { return String(localized: "On the roadmap") }
        switch suggestion.status {
        case .open: return nil
        case .planned: return String(localized: "Planned")
        case .maybe: return String(localized: "Maybe")
        case .notPlanned: return String(localized: "Not planned")
        case .done: return String(localized: "Done")
        }
    }
}

/// One reported problem: number, title, state. No body, no author, no avatar — the feed carries none of
/// that on purpose, and the row cannot invent it.
struct RoadmapIssueRow: View {
    let issue: ProjectIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(issue.title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = ["#\(issue.number)", status]
        if let day = RoadmapDates.day(issue.opened ?? issue.closed)?
            .formatted(date: .abbreviated, time: .omitted) {
            parts.append(day)
        }
        if let version = issue.fixedIn {
            parts.append(String(localized: "in \(version)"))
        }
        return parts.joined(separator: " · ")
    }

    private var status: String {
        switch issue.status {
        case .reported: return String(localized: "Reported")
        case .working: return String(localized: "Being worked on")
        case .fixed: return String(localized: "Fixed")
        case .notPlanned: return String(localized: "Not planned")
        }
    }
}

/// The one place `yyyy-MM-dd` from the files turns into a date. Shared so a card and a row cannot
/// disagree about what a day string means.
enum RoadmapDates {
    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return parser.date(from: raw)
    }
}
