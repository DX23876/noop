import SwiftUI
import StrandCore
import StrandDesign

// ProjectReportViews.swift — reporting a problem from inside the app, and following what became of it.
//
// The screens here are deliberately thin: every rule lives in `StrandCore.ProjectService` and
// `ProjectReportStore`, so the Android twin shows the same words from the same decisions. What this
// file owns is the order things happen in, and that order is the promise:
//
//   write → (see the log you are about to attach) → send → the code → the thread
//
// The log step is not skippable and not silent. It is the same review gate the Test Centre has used
// since the beginning: the exact bundle, shown, then an explicit press. A log carries device details
// and sometimes more, so the only honest way to send one is to show it first.

/// The state behind reporting: the draft, what this device has reported, and one thread at a time.
@MainActor
final class ProjectReportModel: ObservableObject {
    @Published var draft = ""
    /// On by default: somebody who reports a problem usually wants the question that follows.
    @Published var wantsThread = true
    @Published var attachLog = true
    @Published var isSending = false
    @Published var sentCode: String?
    @Published var sentWithoutThread = false
    @Published var failed = false
    @Published var mine: [ProjectReportStore.Entry] = []

    private let store = ProjectReportStore.standard
    private var service: ProjectService?

    /// True once the feed carries an address and the wearer has not switched sending off.
    @Published var canWrite = false

    func load() async {
        let page = await ProjectPageStore(directory: RoadmapModel.cacheDirectory).cached()
        let service = ProjectService(service: page.service)
        self.service = service
        canWrite = await service.isAvailable
        mine = store.all()
    }

    var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.count <= ProjectService.maximumReport
    }

    /// Send the report, then the log if one was built and confirmed. The log goes second on purpose:
    /// without a code there is nowhere to put it, and a report that arrived without its log is still
    /// a report, while a log without a report is nothing at all.
    func send(log: Data?) async {
        guard let service else { return }
        isSending = true
        failed = false
        let result = await service.report(text: draft, wantsThread: wantsThread)
        switch result {
        case .sent(let code):
            if let code {
                store.add(.init(code: code, title: ProjectReportModel.firstLine(draft), sent: Date()))
                if let log { _ = await service.sendLog(code: code, data: log) }
                sentCode = code
            } else {
                sentWithoutThread = true
            }
            draft = ""
            mine = store.all()
        case .refused, .unreachable:
            failed = true
        }
        isSending = false
    }

    func forget(code: String) {
        store.remove(code: code)
        mine = store.all()
    }

    /// Taking a report back: the log is deleted on the service, then it leaves this device's list.
    func withdraw(code: String) async {
        guard let service else { return }
        if case .sent = await service.withdraw(code: code) { forget(code: code) }
    }

    func thread(code: String) async -> ProjectThread? {
        guard let service else { return nil }
        let thread = await service.thread(code: code)
        if let thread {
            // Reading it is seeing it, so the daily check does not announce what is already on screen.
            store.seen(code: code, status: thread.status, messages: thread.messages.count)
            mine = store.all()
        }
        return thread
    }

    func reply(code: String, text: String) async -> Bool {
        guard let service else { return false }
        if case .sent = await service.reply(code: code, text: text) { return true }
        return false
    }

    /// A code typed back in after a new install. Nothing is verified here: the thread screen asks the
    /// service, and a code that means nothing answers exactly like one that was withdrawn.
    func adopt(code: String) {
        let cleaned = code.uppercased().trimmingCharacters(in: .whitespaces)
        guard ProjectService.isReportCode(cleaned) else { return }
        store.add(.init(code: cleaned, title: String(localized: "A report you sent earlier"),
                        sent: Date()))
        mine = store.all()
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return String(line.trimmingCharacters(in: .whitespaces).prefix(80))
    }
}

/// The form: what happened, whether questions may come back, and whether the log rides along.
struct ReportProblemView: View {
    @ObservedObject var model: ProjectReportModel
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var live: LiveState
    @Environment(\.dismiss) private var dismiss

    @State private var gate: ReportReviewGate?
    @State private var showingReview = false

    var body: some View {
        ScreenScaffold(title: "Report a problem",
                       subtitle: "It goes to the developer, not to the other people using NOOP") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                if let code = model.sentCode {
                    sentCard(code: code)
                } else if model.sentWithoutThread {
                    ForgeListGroup("Sent") {
                        Text("Thank you. You asked for no way back, so this is the end of it: there is no code, nothing was stored, and nobody can ask you anything about it.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    form
                }
            }
        }
        .sheet(isPresented: $showingReview) {
            if let gate {
                ReportLogReviewSheet(gate: gate) { confirmed in
                    showingReview = false
                    Task { await model.send(log: confirmed ? ReportProblemView.zip(gate.entries) : nil) }
                }
            }
        }
    }

    private var form: some View {
        Group {
            ForgeListGroup("What happened") {
                TextField("What went wrong, and what did you expect?", text: $model.draft, axis: .vertical)
                    .lineLimit(3...10)
                    .font(StrandFont.subhead)
                    .textFieldStyle(.plain)
                Text("\(max(0, ProjectService.maximumReport - model.draft.count)) characters left")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }

            ForgeListGroup("How it is sent") {
                ForgeToggleRow(title: "Allow questions back",
                               subtitle: "You get a code, and a notification when there is an answer",
                               isOn: $model.wantsThread)
                Divider().overlay(StrandPalette.hairline)
                ForgeToggleRow(title: "Attach my log",
                               subtitle: "You see exactly what it contains before anything is sent",
                               isOn: $model.attachLog)
            }

            if !model.wantsThread {
                ForgeListGroup {
                    Text("Without questions back nothing is stored about this report, and nobody can ask you for the detail that would have made it fixable. Say as much as you can in the text.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForgeListGroup {
                ForgeActionRow(title: model.isSending ? "Sending…" : "Send") { startSending() }
                    .disabled(!model.canSend)
                if model.failed {
                    Text("That did not go out. Try again later.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private func sentCard(code: String) -> some View {
        ForgeListGroup("Sent") {
            Text("Keep this code. It is the only way back to this report, and it works on any device.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: code)
                .font(StrandFont.title2.monospaced())
                .foregroundStyle(StrandPalette.textPrimary)
                .textSelection(.enabled)
            ForgeActionRow(title: "Copy the code") { PlatformPasteboard.copy(code) }
            ForgeActionRow(title: "Done") { dismiss() }
        }
    }

    /// With a log: build it, show it, and send only on an explicit press. Without: straight out.
    private func startSending() {
        guard model.attachLog else {
            Task { await model.send(log: nil) }
            return
        }
        Task { @MainActor in
            let storage = await TestCentreReport.storageProbe(repo: app.repo, live: live)
            let model = UserDefaults.standard.string(forKey: "selectedWhoopModel")
            gate = ReportReviewGate(entries: TestBundleAssembler.assemble(
                profile: .master, live: live, storage: storage, strapModel: model))
            showingReview = true
        }
    }

    /// The staged bundle as bytes. Nil when it cannot be written, and then the report goes without it
    /// rather than silently waiting for something that will not come.
    static func zip(_ entries: [FileExport.BundleEntry]) -> Data? {
        guard let url = FileExport.zipData(entries: entries, baseName: "noop-report") else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try? Data(contentsOf: url)
    }
}

/// The exact bundle, before anything leaves. The same gate the Test Centre share has always used.
private struct ReportLogReviewSheet: View {
    let gate: ReportReviewGate
    let finish: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(gate.previewText)
                    .font(StrandFont.caption.monospaced())
                    .foregroundStyle(StrandPalette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("What you are about to send")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Without the log") { finish(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send with the log") { finish(true) }
                }
            }
        }
    }
}

/// What this device has reported, with where each one stands.
struct MyReportsSection: View {
    @ObservedObject var model: ProjectReportModel
    @State private var showingCodeEntry = false
    @State private var typed = ""

    /// The keyboard hint is iOS only; `adopt` upper-cases anyway, so macOS loses nothing by typing it
    /// in lower case.
    private var codeField: some View {
        #if os(iOS)
        TextField("ABCD-EFGH-JKLM-NPQR", text: $typed).textInputAutocapitalization(.characters)
        #else
        TextField("ABCD-EFGH-JKLM-NPQR", text: $typed)
        #endif
    }

    var body: some View {
        ForgeListGroup("Your reports",
                       note: "Only on this device. The code is what carries a report to another one.") {
            if model.mine.isEmpty {
                Text("Nothing yet.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                ForEach(model.mine) { entry in
                    NavigationLink {
                        ProjectThreadView(model: model, entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(ProjectThreadView.statusText(entry.seenStatus))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider().overlay(StrandPalette.hairline)
            ForgeActionRow(title: "I have a code",
                           subtitle: "Bring a report back after a new install") {
                showingCodeEntry = true
            }
        }
        .alert("Your code", isPresented: $showingCodeEntry) {
            codeField
            Button("Add") { model.adopt(code: typed); typed = "" }
            Button("Cancel", role: .cancel) { typed = "" }
        } message: {
            Text("Four groups of four, from the report you sent.")
        }
    }
}

/// One report: where it stands, what was said, and the way to answer or take it back.
struct ProjectThreadView: View {
    @ObservedObject var model: ProjectReportModel
    let entry: ProjectReportStore.Entry

    @State private var thread: ProjectThread?
    @State private var loaded = false
    @State private var draft = ""
    @State private var sending = false
    @State private var showingWithdraw = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenScaffold(title: "Your report", onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                Text(entry.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                statusCard
                messagesCard
                replyCard
                codeCard
            }
        }
        .task { await reload() }
        .confirmationDialog("Withdraw this report?", isPresented: $showingWithdraw,
                            titleVisibility: .visible) {
            Button("Withdraw", role: .destructive) {
                Task { await model.withdraw(code: entry.code); dismiss() }
            }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text("The log is deleted and the code stops working. What was already fixed stays fixed.")
        }
    }

    private var statusCard: some View {
        ForgeListGroup("Where it stands") {
            Text(ProjectThreadView.statusText(thread?.status ?? entry.seenStatus))
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            if let version = thread?.fixedIn {
                Text("Fixed in version \(version). Update to get it.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let number = thread?.publicNumber {
                Text("Tracked publicly as #\(number).")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if !loaded {
                Text("Checking…")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var messagesCard: some View {
        if let messages = thread?.messages, !messages.isEmpty {
            ForgeListGroup("The conversation") {
                ForEach(messages) { message in
                    VStack(alignment: message.mine ? .trailing : .leading, spacing: 2) {
                        Text(message.mine ? "You" : "The developer")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text(message.text)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
                }
            }
        } else if loaded {
            ForgeListGroup("The conversation") {
                Text("Nothing said yet. If a question comes, it appears here.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var replyCard: some View {
        ForgeListGroup("Answer") {
            TextField("Anything you can add", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .font(StrandFont.subhead)
                .textFieldStyle(.plain)
            ForgeActionRow(title: sending ? "Sending…" : "Send") {
                Task {
                    sending = true
                    if await model.reply(code: entry.code, text: draft) {
                        draft = ""
                        await reload()
                    }
                    sending = false
                }
            }
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var codeCard: some View {
        ForgeListGroup("This report's code") {
            Text(verbatim: entry.code)
                .font(StrandFont.subhead.monospaced())
                .foregroundStyle(StrandPalette.textSecondary)
                .textSelection(.enabled)
            ForgeActionRow(title: "Copy the code") { PlatformPasteboard.copy(entry.code) }
            Divider().overlay(StrandPalette.hairline)
            ForgeActionRow(title: "Withdraw this report", role: .destructive) {
                showingWithdraw = true
            }
        }
    }

    private func reload() async {
        thread = await model.thread(code: entry.code)
        loaded = true
    }

    static func statusText(_ status: ProjectReportStatus) -> String {
        switch status {
        case .arrived: return String(localized: "Arrived. Nobody has looked at it yet.")
        case .read: return String(localized: "Read.")
        case .working: return String(localized: "Being worked on.")
        case .fixed: return String(localized: "Fixed.")
        case .notPlanned: return String(localized: "Not planned.")
        }
    }
}

/// The one switch over everything this app sends. A quiet row, at the bottom, where a decision of this
/// size belongs: not in a banner, and not asked on first launch.
struct ProjectSharingRow: View {
    @State private var on = ProjectSharing.standard.isOn

    var body: some View {
        ForgeListGroup("Taking part",
                       note: "Off means nothing leaves this device: no thumbs, no wishes, no reports, no recordings. Reading stays.") {
            ForgeToggleRow(title: "Send things from this device",
                           isOn: Binding(get: { on },
                                         set: { on = $0; ProjectSharing.standard.set($0) }))
        }
    }
}
