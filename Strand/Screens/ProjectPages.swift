import SwiftUI
import StrandCore
import StrandDesign

// ProjectPages.swift — the project's four pages and the hub that opens them.
//
// They were one screen until 2026-11-15, with seven sections stacked in one scroll: the plan, a write
// box, and the state of every reported problem. Three different questions, three different rhythms. The
// plan is read once and changes rarely; the problems are looked up when something is broken; writing
// happens seldom. In one list they compete for the same attention, and a wish typed by the reader sat
// below three phases of roadmap before anyone saw it.
//
// Everything still comes from the same two static files through `RoadmapModel`, read when the hub opens
// and at no other time. The model is created once, here, and handed to the pages, so moving between
// them costs no read and the four cannot disagree about what was loaded.

/// The picture at the top of a project page.
///
/// A shipped image, not a drawing. The scenes carry depth, sparks and halation that `Path` cannot, and
/// the owner chose that richness over following the colour profile (2026-11-15). So they stay dark in
/// both themes, the way a photograph does, rather than turning with the palette.
struct ProjectScene: View {
    let name: String
    var height: CGFloat = 150

    var body: some View {
        Image(name)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The way in: four cards, each its own page. No badge, no unread dot, no count that reads as an alarm.
struct ProjectHubView: View {
    @StateObject private var model = RoadmapModel()

    var body: some View {
        ScreenScaffold(
            title: "Project",
            subtitle: "What is planned, what is broken, and what you would like",
            onRefresh: { await model.refresh() }
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ProjectHubCard(scene: "scene_roadmap",
                               title: "Roadmap",
                               line: "What is being built, and what comes after",
                               status: roadmapStatus) {
                    RoadmapView(model: model)
                }
                ProjectHubCard(scene: "scene_problems",
                               title: "Problems",
                               line: "What is reported, what is fixed",
                               status: problemsStatus) {
                    ProjectProblemsView(model: model)
                }
                ProjectHubCard(scene: "scene_wishes",
                               title: "Wishes",
                               line: "Ask for something, or back what others asked for",
                               status: wishesStatus) {
                    ProjectWishesView(model: model)
                }
                ProjectHubCard(scene: "scene_helping",
                               title: "Help build it",
                               line: "Teach the app to recognise your sports",
                               status: nil) {
                    RawDonationView()
                }
                ProjectSharingRow()
                stamp
            }
        }
        .task { await model.load() }
    }

    private var roadmapStatus: String? {
        let planned = model.page.items(.now).count + model.page.items(.next).count
            + model.page.items(.later).count
        guard planned > 0 else { return nil }
        return String(localized: "\(planned) planned")
    }

    /// The same sentence the Problems page puts at its top, resolved here from the same page, so the
    /// card and the page it opens cannot state different numbers.
    private var problemsStatus: String? {
        model.page.reported.isEmpty ? nil : ProjectProblemsView.summary(model.page)
    }

    private var wishesStatus: String? {
        let count = model.page.suggestions.count
        guard count > 0 else { return nil }
        return String(localized: "\(count) published")
    }

    @ViewBuilder
    private var stamp: some View {
        if model.page.isEmpty && model.hasLoaded {
            Text("Nothing could be loaded. The pages need the internet once, then they keep the last copy.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let fetched = model.page.fetchedAt {
            Text("Last checked \(fetched.formatted(date: .abbreviated, time: .shortened))")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

/// One way in: its picture, its name, one line, and what is in there right now.
private struct ProjectHubCard<Destination: View>: View {
    let scene: String
    let title: LocalizedStringKey
    let line: LocalizedStringKey
    let status: String?
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            NoopCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ProjectScene(name: scene, height: 118)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(line)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let status {
                            Text(status)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(NoopMetrics.space4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// What was reported, what is being worked on, what was fixed, and what will not be done.
struct ProjectProblemsView: View {
    @ObservedObject var model: RoadmapModel
    @StateObject private var reports = ProjectReportModel()
    @State private var showAllReported = false

    var body: some View {
        ScreenScaffold(
            title: "Problems",
            subtitle: "Reported by the people using NOOP",
            onRefresh: { await model.refresh() }
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ProjectScene(name: "scene_problems")
                reportSection
                if !reports.mine.isEmpty { MyReportsSection(model: reports) }
                reportedSection
                fixedSection
                decidedSection
                footer
            }
        }
        .task { await reports.load() }
    }

    /// The way in, first on the page: somebody who opens this because something is broken should not
    /// have to read the state of everyone else's problems to find out where to say so.
    @ViewBuilder
    private var reportSection: some View {
        if reports.canWrite {
            ForgeListGroup("Something broken?") {
                ForgeLinkRow(title: "Report a problem",
                             subtitle: "Goes to the developer with your log, if you let it") {
                    ReportProblemView(model: reports)
                }
                if reports.mine.isEmpty {
                    Divider().overlay(StrandPalette.hairline)
                    // A sentence, not a row: `ForgeActionLabel` draws a chevron, and a chevron on
                    // something that does nothing is a promise the screen cannot keep.
                    Text("A report keeps a code, so a question can reach you. You can also send one without that.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One line instead of a number on a card: "8 reported, 1 being worked on". A count that reads as
    /// an alarm is the thing this page is not for. Static so the hub card says it from the same page.
    static func summary(_ page: ProjectPage) -> String {
        if page.workingCount > 0 {
            return String(localized: "\(page.reportedCount) reported, \(page.workingCount) being worked on")
        }
        return String(localized: "\(page.reportedCount) reported")
    }

    @ViewBuilder
    private var reportedSection: some View {
        if model.page.reported.isEmpty {
            ForgeListGroup("Nothing open") {
                Text("No problem is waiting. What arrives shows up here.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ForgeListGroup("Reported problems", note: "Open reports on the project's issue tracker.") {
                Text(ProjectProblemsView.summary(model.page))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                // The label says what a tap does, like the Android twin: a chevron alone leaves the
                // two platforms describing the same control with different words.
                DisclosureGroup(isExpanded: $showAllReported) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        ForEach(model.page.reported) { issue in
                            RoadmapIssueRow(issue: issue)
                        }
                    }
                    .padding(.top, NoopMetrics.space2)
                } label: {
                    Text(showAllReported ? "Show less" : "Show all")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                }
                .tint(StrandPalette.accent)
            }
        }
    }

    @ViewBuilder
    private var fixedSection: some View {
        if !model.page.fixed.isEmpty {
            ForgeListGroup("Recently fixed") {
                ForEach(model.page.fixed) { issue in
                    RoadmapIssueRow(issue: issue)
                }
            }
        }
    }

    @ViewBuilder
    private var decidedSection: some View {
        if !model.page.decided.isEmpty {
            ForgeListGroup("Recently decided",
                           note: "Reports closed without a change. They stay here for a month.") {
                ForEach(model.page.decided) { issue in
                    RoadmapIssueRow(issue: issue)
                }
            }
        }
    }

    private var footer: some View {
        ForgeListGroup {
            // "The long way" only makes sense beside the short one. Without a service address the
            // short way is hidden, and a subtitle implying a quicker route that is nowhere on the
            // screen reads as a fault in the app rather than as a feature that is switched off.
            ForgeLinkRow(title: "Build a log myself",
                         subtitle: reports.canWrite
                             ? "The long way: a redacted file you carry wherever you like"
                             : "A redacted file you can attach wherever you report it") {
                TestCentreView()
            }
            Divider().overlay(StrandPalette.hairline)
            Link(destination: ProjectLinks.issues) {
                ForgeActionLabel(title: "Open the issue tracker",
                                 subtitle: "Reading and writing there happens in your browser")
            }
            .buttonStyle(.plain)
        }
    }
}

/// Ask for something, and back what other people asked for.
struct ProjectWishesView: View {
    @ObservedObject var model: RoadmapModel

    /// This screen's first appearance, so the last wish's confirmation does not greet the next one.
    @State private var opened = false

    var body: some View {
        ScreenScaffold(
            title: "Wishes",
            subtitle: "What people would like NOOP to do",
            onRefresh: { await model.refresh() }
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ProjectScene(name: "scene_wishes")
                howItWorks
                suggestBox
                suggestionsSection
            }
        }
        .task {
            guard !opened else { return }
            opened = true
            // The model outlives this screen, so "Arrived" from a wish sent an hour ago would stand
            // under an empty box as though it had just been sent again.
            model.sentConfirmation = false
            model.sendFailed = false
        }
    }

    /// The five questions somebody asks themselves while typing. They used to be answered by one line
    /// after sending, which said only that nothing is promised: true, and read as a door closing.
    private var howItWorks: some View {
        ForgeListGroup("What happens to what you write") {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                WishFact(icon: "lock.fill",
                         line: "It goes to a private list only the developer reads. Not to the public repository, and not to the other people using NOOP.")
                WishFact(icon: "textformat",
                         line: "What is sent is the text you type. No name, no device, nothing about your body or your training.")
                WishFact(icon: "line.3.horizontal.decrease",
                         line: "A filter reads it first. It merges a wish somebody already asked for, and holds anything unclear for the developer instead of publishing it.")
                WishFact(icon: "bubble.left.and.bubble.right.fill",
                         line: "Published wishes appear below, with the developer's answer, and anyone can back one with a thumb.")
                WishFact(icon: "clock.arrow.circlepath",
                         line: "Most wishes are not built, and nothing here promises when or whether. Being asked for often does make a thing more likely.")
            }
        }
    }

    /// Hidden entirely without a service address, rather than offered and then failing.
    @ViewBuilder
    private var suggestBox: some View {
        if model.canWrite {
            ForgeListGroup("Ask for something") {
                TextField("What would you like NOOP to do?", text: $model.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(StrandFont.subhead)
                    .textFieldStyle(.plain)
                HStack {
                    Text("\(max(0, ProjectService.maximumSuggestion - model.draft.count)) characters left")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    Button("Send") { Task { await model.send() } }
                        .buttonStyle(.plain)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(canSend ? StrandPalette.accent : StrandPalette.textTertiary)
                        .disabled(!canSend)
                }
                if model.sentConfirmation {
                    Text("Arrived. It is read before it appears here, which can take a few days.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.sendFailed {
                    Text("That did not go out. Try again later.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var canSend: Bool {
        !model.isSending
            && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.draft.count <= ProjectService.maximumSuggestion
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        if model.page.suggestions.isEmpty {
            ForgeListGroup("Nothing published yet") {
                Text("Wishes appear here once they have been read. Yours can be the first.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                RoadmapSectionHeader(title: "Published", icon: "lightbulb.fill")
                ForEach(model.page.suggestions) { suggestion in
                    SuggestionCard(suggestion: suggestion,
                                   voted: model.myVotes.contains(suggestion.id),
                                   count: model.counts[suggestion.id],
                                   canVote: model.canWrite,
                                   failed: model.voteFailed == suggestion.id) {
                        Task { await model.vote(suggestion) }
                    }
                }
            }
        }
    }
}

/// One fact about the way a wish travels, as a symbol and a sentence.
private struct WishFact: View {
    let icon: String
    /// Named `line` rather than `text`: that is what the audit reads as copy, and a fact nobody
    /// can see is how five of these shipped in English.
    let line: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 22, alignment: .center)
                .accessibilityHidden(true)
            Text(line)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
