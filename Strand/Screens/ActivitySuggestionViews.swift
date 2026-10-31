import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore

// MARK: - Activity detection on screen (fork decision 2026-10-31)
//
// Three surfaces, one state (`ActivitySuggestionCenter`): the fixed prompt at the top of Today, the rows in
// the Updates inbox and the logging sheet, which every path opens. The colour is Effort's, the domain the
// detected movement belongs to; the one graphic is the span's own heart rate as a glowing thread.

/// The prompt pinned above Today's reorderable cards. It slides in when something was detected and stays
/// until it is answered or put off with "Later"; with several open it names the newest and how many more.
struct ActivitySuggestionPrompt: View {
    @EnvironmentObject var repo: Repository
    @ObservedObject private var center = ActivitySuggestionCenter.shared
    @State private var showList = false

    var body: some View {
        let toAsk = center.toAsk
        VStack(spacing: 0) {
            if let s = toAsk.first {
                ActivitySuggestionCard(suggestion: s, more: toAsk.count - 1, onMore: { showList = true })
                    .id(s.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(StrandMotion.interactive, value: toAsk.first?.id)
        .task {
            center.attach(repo)
            await center.reload()
        }
        .sheet(isPresented: $showList) {
            ActivitySuggestionListSheet()
        }
    }
}

/// One suggestion as a card, built to the SwiftUI design rules (grid spacing of 4, 8, 12 and 16, five type
/// sizes, one accent): what was detected, how long as the one large number, when and how hard in one line,
/// the span's own heart rate as the dashboard's glowing thread, and one row of three compact answers.
struct ActivitySuggestionCard: View {
    @EnvironmentObject var repo: Repository
    let suggestion: ActivitySuggestions.Suggestion
    var more: Int = 0
    var onMore: (() -> Void)?
    @State private var curve: [Double] = []
    @State private var busy = false

    private var center: ActivitySuggestionCenter { .shared }
    /// Effort's colour: detected movement belongs to that domain. The only accent on the card.
    private var tint: Color { StrandPalette.effortColor }

    var body: some View {
        NoopCard(padding: 16, tint: tint, kind: .state) {
            VStack(alignment: .leading, spacing: 12) {
                header
                hero
                answers
                if more > 0, let onMore {
                    Button(action: onMore) {
                        Text("\(more) more")
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: suggestion.id) {
            center.markShown(suggestion)
            // `to` is inclusive in the read; the span's end minute belongs to what came after it.
            let buckets = await repo.hrBuckets(from: suggestion.start, to: suggestion.end - 1, bucketSeconds: 60)
            curve = buckets.filter { $0.sampleSeconds > 0 }.map(\.bpm)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(suggestion.likelyKind))
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            Text(ActivitySuggestionNotifier.title(suggestion))
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
            Button {
                StrandHaptic.selection.play()
                withAnimation(StrandMotion.interactive) { center.snooze(suggestion) }
            } label: {
                Image(systemName: "xmark")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Later")
        }
    }

    /// The length as the one large number, light rather than heavy; the span and the average heart rate in one
    /// secondary line under it; the heart-rate thread beside it.
    private var hero: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(suggestion.durationMinutes)")
                        .font(StrandFont.rounded(40, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                    Text("min")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text(detailLine)
                    .font(StrandFont.footnote)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            if curve.count >= 2 {
                Canvas { ctx, size in
                    LiquidRender.thread(ctx, size, values: curve, now: 0, tint: tint)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            }
        }
    }

    /// "Today, 18:54 to 19:30 · avg 106 bpm"
    private var detailLine: String {
        let when = ActivitySuggestionNotifier.whenLine(suggestion)
        guard let avg = suggestion.avgBpm else { return when }
        return when + " · " + String(localized: "avg \(avg) bpm")
    }

    /// One row of three compact answers: save as the most likely kind; the next kinds, housework and the
    /// logging sheet behind one menu; "Not training" to discard it for good.
    private var answers: some View {
        let likely = suggestion.likelyKind
        let others = (suggestion.track == .walk ? [ActivityDetectionScore.Kind.run, .strength]
                                                : Array(suggestion.kinds.dropFirst().prefix(2)))
            .filter { $0 != likely }
        return HStack(spacing: 8) {
            Button {
                confirm(likely)
            } label: {
                Label(ActivitySuggestionCenter.kindName(likely), systemImage: "checkmark")
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(ActivitySuggestionNotifier.saveTitle(likely))
            Menu {
                ForEach(others, id: \.self) { kind in
                    Button {
                        confirm(kind)
                    } label: {
                        Label(ActivitySuggestionCenter.kindName(kind), systemImage: Self.symbol(kind))
                    }
                }
                Button {
                    answer(.housework)
                } label: {
                    Label("Housework", systemImage: "house")
                }
                Divider()
                Button {
                    center.openRequest = .init(suggestion: suggestion, origin: .today)
                } label: {
                    Label("Adjust", systemImage: "slider.horizontal.3")
                }
            } label: {
                Text("Other kind…").lineLimit(1)
            }
            .buttonStyle(.bordered)
            Button {
                answer(.everyday)
            } label: {
                Text("Not training").lineLimit(1)
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .font(StrandFont.subhead.weight(.semibold))
        .controlSize(.small)
        .tint(tint)
        .disabled(busy)
    }

    private func confirm(_ kind: ActivityDetectionScore.Kind) {
        busy = true
        StrandHaptic.success.play()
        Task {
            await center.confirm(suggestion, row: ActivitySuggestionCenter.prefill(suggestion, kind: kind), origin: .today)
            busy = false
        }
    }

    private func answer(_ a: ActivitySuggestionAnswer.Answer) {
        busy = true
        StrandHaptic.selection.play()
        Task {
            await center.answer(suggestion, a, origin: .today)
            busy = false
        }
    }

    static func symbol(_ kind: ActivityDetectionScore.Kind) -> String {
        switch kind {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "figure.outdoor.cycle"
        case .strength: return "figure.strengthtraining.traditional"
        case .other: return "waveform.path.ecg"
        }
    }
}

// MARK: - Inbox rows

/// The suggestions of the last two weeks for the Updates inbox: open ones first, then the answered ones
/// faded, each with Undo. Renders nothing while detection is off or nothing was detected.
struct ActivitySuggestionInboxSection: View {
    @EnvironmentObject var repo: Repository
    @ObservedObject private var center = ActivitySuggestionCenter.shared
    /// The inbox is itself a sheet, so the logging sheet opens from here rather than from the app root.
    @State private var opening: ActivitySuggestions.Suggestion?

    var body: some View {
        let rows = center.inbox
        Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    Text("Detected activities")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    ForEach(rows) { s in ActivitySuggestionRow(suggestion: s) { opening = s } }
                }
            }
        }
        .task {
            center.attach(repo)
            await center.reload()
        }
        .sheet(item: $opening) { s in
            ManualWorkoutSheet(prefill: ActivitySuggestionCenter.prefill(s), hrSource: repo) { row, _ in
                Task { await center.confirm(s, row: row, origin: .inbox) }
            }
        }
    }
}

struct ActivitySuggestionRow: View {
    let suggestion: ActivitySuggestions.Suggestion
    let onAnswer: () -> Void
    private var center: ActivitySuggestionCenter { .shared }

    var body: some View {
        let open = suggestion.state == .open
        HStack(spacing: 12) {
            Image(systemName: ActivitySuggestionCard.symbol(suggestion.likelyKind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.effortColor)
                .frame(width: 28, height: 28)
                .background(StrandPalette.effortColor.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ActivitySuggestionNotifier.title(suggestion))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(ActivitySuggestionNotifier.spanLine(suggestion))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !open {
                    Text(stateLine)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            switch suggestion.state {
            case .open:
                Button("Answer", action: onAnswer)
                    .buttonStyle(.bordered)
                    .font(StrandFont.subhead)
            case .answered:
                Button("Undo") { Task { await center.undo(suggestion) } }
                    .buttonStyle(.plain)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.effortColor)
            case .logged:
                EmptyView()
            }
        }
        .opacity(open ? 1 : 0.6)
        .padding(12)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var stateLine: String {
        switch suggestion.state {
        case .open: return ""
        case .logged: return String(localized: "Already in your workouts")
        case .answered(let a):
            switch a {
            case .walk: return String(localized: "Saved as walk")
            case .sport: return String(localized: "Saved as training")
            case .everyday: return String(localized: "Not training")
            case .housework: return String(localized: "Housework")
            }
        }
    }
}

/// "+N more" on the prompt: the same list the inbox shows, on its own sheet.
struct ActivitySuggestionListSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ActivitySuggestionInboxSection()
                    .padding(20)
            }
            .navigationTitle(Text("Detected activities"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #else
        .frame(width: 460, height: 560)
        #endif
    }
}

// MARK: - Sheet host

/// Presents the logging sheet for a suggestion from anywhere: a notification tap, "Other kind…" on the
/// prompt, "Answer" in the inbox. Saving confirms the suggestion under its own source.
struct ActivitySuggestionSheetHost: ViewModifier {
    @ObservedObject private var center = ActivitySuggestionCenter.shared
    let repo: Repository

    func body(content: Content) -> some View {
        content
            .sheet(item: $center.openRequest) { request in
                ManualWorkoutSheet(prefill: ActivitySuggestionCenter.prefill(request.suggestion), hrSource: repo) { row, _ in
                    Task { await center.confirm(request.suggestion, row: row, origin: request.origin) }
                }
            }
            .task { center.attach(repo) }
    }
}

extension View {
    func activitySuggestionSheetHost(_ repo: Repository) -> some View {
        modifier(ActivitySuggestionSheetHost(repo: repo))
    }
}
