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
    /// The report went, the log did not. Said out loud rather than left to be noticed: the wearer saw
    /// the whole bundle and pressed send with it, so silence here would be the screen quietly dropping
    /// the half they looked hardest at.
    @Published var logFailed = false
    @Published var mine: [ProjectReportStore.Entry] = []
    /// The assembled bundle, waiting for the wearer to confirm or refuse it. Here rather than in the
    /// view: a pushed screen's `@State` does not survive its parent re-rendering, and this one has to
    /// outlive exactly that.
    @Published var staged: ReportReviewGate?
    @Published var isPreparing = false

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
        logFailed = false
        let result = await service.report(text: draft, wantsThread: wantsThread,
                                          language: ProjectReportModel.language())
        switch result {
        case .sent(let code):
            if let code {
                store.add(.init(code: code, title: ProjectReportModel.firstLine(draft), sent: Date()))
                if let log {
                    if case .sent = await service.sendLog(code: code, data: log) {} else {
                        logFailed = true
                    }
                }
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

    /// The language the app talks to this person in. `AppLanguage` is what they chose in Settings; only
    /// when they left it on System does the phone's own language decide. Taking the phone's language
    /// outright is how an answer comes back in a language somebody does not read: the owner's own first
    /// report arrived marked `en` from a phone set to English, written in German.
    static func language() -> String {
        let chosen = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
        if let chosen, let language = AppLanguage(rawValue: chosen), language != .system {
            return language.rawValue
        }
        return ProjectService.currentLanguage
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
        // Driven off the model, so the sheet cannot be lost when this screen is rebuilt.
        .sheet(isPresented: Binding(get: { model.staged != nil },
                                    set: { if !$0 { model.staged = nil } })) {
            if let gate = model.staged {
                ReportLogReviewSheet(gate: gate) { confirmed in
                    model.staged = nil
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
                ForgeActionRow(title: sendTitle) { startSending() }
                    .disabled(!model.canSend || model.isPreparing)
                if model.failed {
                    Text("That did not go out. Try again later.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    /// Says which of the three things is happening, never the wrong one: preparing the log is not
    /// sending, and saying "Sending…" while nothing has left would be a line that claims more than
    /// it observes.
    private var sendTitle: LocalizedStringKey {
        if model.isPreparing { return "Preparing…" }
        return model.isSending ? "Sending…" : "Send"
    }

    private func sentCard(code: String) -> some View {
        ForgeListGroup("Sent") {
            Text("Keep this code. It is the only way back to this report, and it works on any device.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.logFailed {
                Text("The report arrived. The log did not: it was too large, or the service refused it.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        model.isPreparing = true
        Task { @MainActor in
            let storage = await ReportProblemView.storageWithinReach(repo: app.repo, live: live)
            let strap = UserDefaults.standard.string(forKey: "selectedWhoopModel")
            let entries = TestBundleAssembler.assemble(profile: .master, live: live,
                                                       storage: storage, strapModel: strap)
            model.isPreparing = false
            // Nothing to show means nothing to attach. The report still goes, rather than opening an
            // empty sheet and asking somebody to confirm a bundle that is not there.
            guard !entries.isEmpty else {
                await model.send(log: nil)
                return
            }
            model.staged = ReportReviewGate(entries: entries)
        }
    }

    /// The storage block: the part that is free always, the part that is expensive only if it is quick.
    ///
    /// `storageProbe` does two different things under one name. Reading file sizes is a stat call and
    /// costs nothing. Counting rows walks every accumulating table, waveform blobs included, which on a
    /// store with years of history is minutes on the phone. Both hung on the same deadline, so missing
    /// the deadline threw away the database size too, and that is the number somebody usually wants.
    ///
    /// So the sizes are read here and kept whatever happens, and the full probe is raced against a
    /// deadline on top. Its answer is a superset, so when it arrives it wins. What is not read stays
    /// zero, which is what meta.json already means by zero: not measured, never a claim that it is
    /// empty.
    static func storageWithinReach(repo: Repository?, live: LiveState,
                                   seconds: Double = 6) async -> TestBundleMeta.Storage? {
        let quick = ReportProblemView.fileSizesOnly()
        let full = await withTaskGroup(of: TestBundleMeta.Storage?.self) { group in
            group.addTask { await TestCentreReport.storageProbe(repo: repo, live: live) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return full ?? quick
    }

    /// Database and raw-capture sizes off the filesystem. No query, no scan, no store handle.
    static func fileSizesOnly() -> TestBundleMeta.Storage? {
        let fm = FileManager.default
        var dbBytes = 0
        if let path = try? StorePaths.defaultDatabasePath() {
            for suffix in ["", "-wal", "-shm"] {
                dbBytes += (try? fm.attributesOfItem(atPath: path + suffix))?[.size] as? Int ?? 0
            }
        }
        guard dbBytes > 0 else { return nil }
        return TestBundleMeta.Storage(dbBytes: dbBytes, rows: [:], rawCaptureBytes: 0, rowBytes: [:])
    }

    /// The staged bundle as bytes. Nil when it cannot be written, and then the report goes without it
    /// rather than silently waiting for something that will not come.
    static func zip(_ entries: [FileExport.BundleEntry]) -> Data? {
        guard let url = FileExport.zipData(entries: entries, baseName: "noop-report") else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try? Data(contentsOf: url)
    }
}

/// The exact bundle, before anything leaves, and this time all of it.
///
/// `ReportReviewGate.previewText` stops inlining a file at 1 MiB and names it instead, which is right
/// for its own sheet: a SwiftUI `Text` of megabytes pins the main thread in glyph layout, and a 12 MB
/// one once allocated over a gigabyte. But a strap log is two megabytes, so the file the wearer most
/// needs to see was the one they never saw, under a screen that said they saw everything.
///
/// So the text is whole, and it is handed to the platform's own text view, which was built for
/// exactly this and lays out long documents lazily. Binary entries are still named: there is nothing
/// to read in a PNG, and the name is the honest statement about it.
private struct ReportLogReviewSheet: View {
    let gate: ReportReviewGate
    let finish: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ReportBundleText(text: ReportLogReviewSheet.wholeBundle(gate.entries))
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

    /// Every text file in full, each under its own header, and the binary ones named. No cap: the cap
    /// is what hid the log.
    static func wholeBundle(_ entries: [FileExport.BundleEntry]) -> String {
        var parts: [String] = []
        var named: [String] = []
        for entry in entries {
            if let text = String(data: entry.data, encoding: .utf8) {
                parts.append("=== \(entry.name) (\(entry.data.count) bytes) ===\n\(text)")
            } else {
                named.append("\(entry.name) (\(entry.data.count) bytes)")
            }
        }
        if !named.isEmpty {
            parts.append("=== attached, nothing to read in it ===\n" + named.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// The platform's own text view. SwiftUI's `Text` lays a whole string out at once, which is why the
/// gate caps what it inlines; this one lays out what is on screen.
private struct ReportBundleText: View {
    let text: String

    var body: some View {
        #if os(iOS)
        ReportBundleTextView(text: text)
        #else
        ScrollView {
            Text(text)
                .font(StrandFont.caption.monospaced())
                .foregroundStyle(StrandPalette.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NoopMetrics.space4)
        }
        #endif
    }
}

#if os(iOS)
private struct ReportBundleTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
#endif

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
