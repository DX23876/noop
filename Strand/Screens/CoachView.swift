import SwiftUI
import MarkdownUI
import StrandDesign
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Coach, the one feature in NOOP that talks to the network.
///
/// Strictly opt-in, bring-your-own-key: the user pastes their own provider API key (stored in the
/// Keychain by `AICoachEngine`), and only a compact text summary of their metrics plus their question
/// ever leaves the device. Nothing is sent until a key is saved and a question asked.
///
/// This is the redesigned full-screen messenger chat: a slim header, a transcript that fills the
/// screen, and a docked composer. All the provider/consent/persona/memory settings live in
/// `CoachSettingsView` (behind the gear); past conversations live in `CoachHistoryView` (the history
/// button). See `docs/CONTRIBUTING.md` for the design-system rules this screen follows.
struct CoachView: View {
    @EnvironmentObject var coach: AICoachEngine

    /// Draft text in the composer (the question being typed).
    @State private var draft: String = ""
    @FocusState private var composerFocused: Bool
    /// Presented sheet: all configuration, or the conversation history. One enum-driven sheet rather
    /// than two stacked `.sheet` modifiers (which don't compose reliably).
    private enum ActiveSheet: Int, Identifiable { case settings, history, plan; var id: Int { rawValue } }
    @State private var activeSheet: ActiveSheet?
    /// First-run goal onboarding (offered once, skippable — see the `.task` that arms it).
    @State private var showGoalOnboarding = false
    /// Drives the header's pending-proposal dot.
    @ObservedObject private var planStore = CoachPlanStore.shared
    #if os(iOS)
    /// Extra clearance the composer needs to clear RootTabView's floating tab bar, which is drawn on
    /// top of pushed content and isn't part of this screen's own safe area. Zero everywhere else: a
    /// `.coachCover` full-screen presentation (no bar drawn over it — see that helper) and every
    /// macOS build (no such key exists there at all, hence this whole property being iOS-only).
    @Environment(\.floatingTabBarInset) private var floatingTabBarInset
    #endif

    private let suggestions = [
        String(localized: "How's my charge trending?"),
        String(localized: "What should today's training look like?"),
        String(localized: "Analyse my sleep"),
        String(localized: "Why am I run down?"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            if coach.isConfigured {
                chatBody
            } else {
                notConnected
            }
        }
        .background(chatBackground)
        // Docked composer: pinned to the bottom, rising above the keyboard on iOS. Only once connected.
        .safeAreaInset(edge: .bottom) {
            if coach.isConfigured { composer }
        }
        .sheet(item: $activeSheet) { which in
            switch which {
            case .settings: CoachSettingsView().environmentObject(coach)
            case .history:  CoachHistoryView(onPick: { activeSheet = nil }).environmentObject(coach)
            case .plan:     CoachPlanView().environmentObject(coach)
            }
        }
        .task(id: coach.dataConsent) { await coach.startBriefIfNeeded() }
        // Tapping the daily check-in notification (routed here by RootTabView) forces a fresh brief.
        .onReceive(NotificationCenter.default.publisher(for: .noopOpenCoachCheckIn)) { _ in
            Task { await coach.refreshBrief() }
        }
        // Goal onboarding: offered ONCE, only to a configured coach with no goal yet, and skippable.
        // The flag is set whichever way the sheet closes, so declining is respected permanently — you
        // can always set a goal later from settings, and NOOP is fully usable without one.
        .task {
            guard coach.isConfigured,
                  CoachGoalStore.shared.goal == nil,
                  !UserDefaults.standard.bool(forKey: Self.goalOnboardingAskedKey) else { return }
            showGoalOnboarding = true
        }
        .sheet(isPresented: $showGoalOnboarding) {
            CoachGoalEditorView(isOnboarding: true) {
                UserDefaults.standard.set(true, forKey: Self.goalOnboardingAskedKey)
            }
        }
    }

    /// Set once the goal onboarding has been offered — saved or skipped — so it never nags twice.
    static let goalOnboardingAskedKey = "coach.goalOnboardingAsked"

    /// The full-bleed day-of-sky backdrop the liquid tabs carry, so Coach sits in one atmosphere.
    private var chatBackground: some View {
        liquidScaffoldSky(height: 240)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { activeSheet = .history } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Conversation history")

            VStack(spacing: 1) {
                Text(coach.activeConversation?.title.isEmpty == false
                     ? coach.activeConversation!.title
                     : String(localized: "Coach"))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                if coach.sending {
                    Text("Thinking…")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 14) {
                // The plan book. The dot means something is waiting for YOUR answer — the coach can
                // propose, but only you can turn a suggestion into a plan.
                Button { activeSheet = .plan } label: {
                    Image(systemName: "calendar")
                        .font(StrandFont.headline)
                        .foregroundStyle(planStore.pending.isEmpty
                                         ? StrandPalette.textSecondary : StrandPalette.accent)
                        .overlay(alignment: .topTrailing) {
                            if !planStore.pending.isEmpty {
                                Circle().fill(StrandPalette.accent)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 3, y: -2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(planStore.pending.isEmpty
                                    ? "Your plan"
                                    : "Your plan, \(planStore.pending.count) waiting for your decision")

                Button { coach.newConversation() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(coach.sending || coach.messages.isEmpty)
                .accessibilityLabel("New chat")

                Button { activeSheet = .settings } label: {
                    Image(systemName: "gearshape")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Coach settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Chat body (connected)

    private var chatBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if coach.messages.isEmpty {
                        emptyState
                    }
                    ForEach(Array(coach.messages.enumerated()), id: \.element.id) { index, message in
                        if shouldShowTimestamp(at: index) {
                            timeSeparator(message.date)
                        }
                        bubble(message).id(message.id)
                    }
                    if coach.sending {
                        typingIndicator.id("typing")
                    }
                    if let error = coach.errorText, !error.isEmpty {
                        errorBanner(error).id("error")
                    }
                    // Suggestion chips live at the bottom of an empty transcript, just above the composer.
                    if coach.messages.isEmpty {
                        suggestionChips.padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChangeCompat(of: coach.messages.count) { _ in scrollToEnd(proxy) }
            .onChangeCompat(of: coach.sending) { sending in
                scrollToEnd(proxy)
                // Announce completion (not every token) so a VoiceOver user knows a reply landed —
                // a streamed reply otherwise gives no signal beyond the initial "Coach is thinking".
                if !sending, coach.errorText == nil { announceReplyComplete() }
            }
            // Keep pinned to the bottom as a streamed reply grows token-by-token.
            .onChangeCompat(of: coach.messages.last?.text.count ?? 0) { _ in scrollToEnd(proxy) }
            // A failed send must scroll into view even if the transcript's message COUNT didn't change
            // (the failed turn's placeholder is removed, not appended) — otherwise the error can sit
            // scrolled off-screen after a long prior reply.
            .onChangeCompat(of: coach.errorText) { _ in scrollToEnd(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask your first question")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Coach reads a summary of your last two weeks plus 30-day averages and recent workouts, then answers in plain language. Try a suggestion below.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.bottom, 4)
    }

    // MARK: - Not connected (no key yet)

    private var notConnected: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(StrandPalette.accent)
            Text("Connect a provider to start")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Coach uses your own API key. Nothing leaves \(Platform.deviceNounPhrase) until you connect and ask a question.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            NoopButton("Connect a provider", systemImage: "link", kind: .primary) { activeSheet = .settings }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Bubbles

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: CoachRadius.bubble, style: .continuous))
                    .frame(maxWidth: 520, alignment: .trailing)
                    .contextMenu { copyButton(message.text) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(message.text)")
        case .assistant:
            // A message the coach backed with a chart (plot_metric) renders as a native chart card; every
            // other assistant message renders its Markdown reply. An empty assistant message with no chart
            // is a stale chart host from before persistence — skip it rather than show a blank bubble.
            if let chart = coach.chartsByMessage[message.id] {
                CoachChartBubble(artifact: chart)
            } else if !message.text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Markdown(message.text)
                            .markdownTheme(.strand)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: CoachRadius.card)
                            .frame(maxWidth: 560, alignment: .leading)
                            .contextMenu {
                                copyButton(message.text)
                                if isLastAssistant(message) {
                                    Button { coach.regenerate() } label: {
                                        Label("Regenerate", systemImage: "arrow.clockwise")
                                    }
                                    .disabled(coach.sending)
                                }
                            }
                        Spacer(minLength: 48)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Coach said: \(message.text)")

                    // Visible, not just a long-press away — the context menu above still works too.
                    if isLastAssistant(message) {
                        Button { coach.regenerate() } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(coach.sending)
                        .padding(.leading, 14)
                        .accessibilityLabel("Regenerate this reply")
                    }
                }
            }
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button { CoachClipboard.copy(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
    }

    private var typingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(StrandPalette.accent)
            Text("Coach is thinking…")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: CoachRadius.card)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityLabel("Coach is thinking")
    }

    /// A failure used to strand the user with the question still typed and no one-tap way back. `Retry`
    /// reuses `regenerate()`: after a failed send there's a user turn with no assistant reply after it
    /// (the empty placeholder was already removed on error), so dropping from that turn and resending
    /// is exactly a retry of the same question — no separate code path needed.
    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StrandPalette.statusCritical)
                    .accessibilityHidden(true)
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Error: \(message)")

            Button { coach.regenerate() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusCritical)
            }
            .buttonStyle(.plain)
            .disabled(coach.sending)
            .accessibilityLabel("Retry sending your last message")
        }
        .padding(14)
        .background(StrandPalette.surfaceOverlay, in: RoundedRectangle(cornerRadius: CoachRadius.card, style: .continuous))
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { prompt in
                    Button { send(prompt) } label: {
                        Text(prompt)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
                            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(LiquidPressStyle())
                    .disabled(coach.sending)
                    .accessibilityLabel("Suggested prompt: \(prompt)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    // MARK: - Composer (docked)

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Coach about your data…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                    .strokeBorder(composerFocused ? StrandPalette.focusRing : StrandPalette.hairline, lineWidth: 1))
                .onSubmit { send(draft) }
                .accessibilityLabel("Question")

            sendOrStopButton
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CoachRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CoachRadius.card, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .padding(.horizontal, 12)
        // Base breathing room above the safe area, unconditionally. On top of it, ADD whatever the
        // floating tab bar needs (0 outside the tab shell — see the property above) rather than
        // replacing this, so the composer keeps its normal spacing when there's no bar to clear.
        .padding(.bottom, 8 + composerFloatingBarClearance)
    }

    /// 0 on macOS and inside `.coachCover` (no floating bar there); the bar's measured height inside
    /// RootTabView's pushed content (e.g. Coach opened from the More list — the "composer hidden
    /// behind the tab bar" bug this exists to fix).
    private var composerFloatingBarClearance: CGFloat {
        #if os(iOS)
        floatingTabBarInset
        #else
        0
        #endif
    }

    /// While a reply streams, the send affordance becomes a Stop button; otherwise it sends the draft.
    private var sendOrStopButton: some View {
        Button {
            if coach.sending { coach.stop() } else { send(draft) }
        } label: {
            Image(systemName: coach.sending ? "stop.fill" : "arrow.up")
                .font(StrandFont.headline)
                .frame(width: 44, height: 38)
                .foregroundStyle(StrandPalette.goldDeepText)
                .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!coach.sending && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(coach.sending ? "Stop" : "Send")
    }

    // MARK: - Helpers

    /// Show a time separator before the first message and whenever more than ~30 minutes passed since
    /// the previous turn, so long chats gain temporal structure without a stamp on every bubble.
    private func shouldShowTimestamp(at index: Int) -> Bool {
        guard index < coach.messages.count else { return false }
        guard index > 0 else { return true }
        let prev = coach.messages[index - 1].date
        let cur = coach.messages[index].date
        return cur.timeIntervalSince(prev) > 30 * 60
    }

    private func timeSeparator(_ date: Date) -> some View {
        Text(date.formatted(.relative(presentation: .named)))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
    }

    private func isLastAssistant(_ message: ChatMessage) -> Bool {
        coach.messages.last(where: { $0.role == .assistant })?.id == message.id
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coach.sending else { return }
        draft = ""
        composerFocused = false
        coach.startSend(trimmed)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(StrandMotion.fade) {
            if coach.sending {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let error = coach.errorText, !error.isEmpty {
                proxy.scrollTo("error", anchor: .bottom)
            } else if let last = coach.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// Post a VoiceOver announcement without narrating every streamed token — only the moment a reply
    /// finishes. Cross-platform: `UIAccessibility`/`NSAccessibility` are the only APIs for this, so there
    /// is no shared abstraction to reuse (unlike `onChangeCompat`, which papers over an API-shape
    /// difference rather than a platform-exclusive one).
    private func announceReplyComplete() {
        let message = String(localized: "Coach replied")
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #elseif canImport(AppKit)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                            userInfo: [.announcement: message])
        #endif
    }
}

extension View {
    /// Present the Coach chat over a screen: fullScreenCover on iOS, a sheet on macOS (no
    /// fullScreenCover there). The engine is passed in (a `View` extension can't read the caller's
    /// @EnvironmentObject) and re-injected so the presented chat inherits it. Used by the Today entries.
    @ViewBuilder func coachCover(isPresented: Binding<Bool>, coach: AICoachEngine) -> some View {
        let content = NavigationStack {
            CoachView()
                .environmentObject(coach)
                #if os(iOS)
                // This is always a true full-screen presentation — no floating tab bar is ever drawn
                // over it. Reset explicitly rather than relying on the caller not having one: the
                // Today-card entry point calls `.coachCover` on Today's OWN view, which — being a
                // descendant of RootTabView's TabView — would otherwise inherit its non-zero
                // `floatingTabBarInset` and add a gap the composer doesn't need here.
                .environment(\.floatingTabBarInset, 0)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { isPresented.wrappedValue = false }
                    }
                }
        }
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) { content }
        #else
        self.sheet(isPresented: isPresented) { content }
        #endif
    }
}

/// One source of truth for the Coach UI's corner radii, so the chat's bubbles / composer / cards don't
/// scatter magic numbers. Kept local to Coach rather than added to the shared design system.
enum CoachRadius {
    static let bubble: CGFloat = 14
    static let card: CGFloat = 16
    static let field: CGFloat = 12
}

/// Cross-platform clipboard write for the Copy affordance (this screen compiles for iOS and macOS).
enum CoachClipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
