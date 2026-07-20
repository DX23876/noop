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
    /// Injected at the app root (`StrandApp`/`StrandiOSApp`) — resolves from the environment wherever
    /// this view is actually presented, since Coach is always reached from within that root's hierarchy.
    @EnvironmentObject var navRouter: NavRouter

    /// Draft text in the composer (the question being typed).
    @State private var draft: String = ""
    @FocusState private var composerFocused: Bool
    /// Presented sheet: all configuration, or the conversation history. One enum-driven sheet rather
    /// than two stacked `.sheet` modifiers (which don't compose reliably).
    private enum ActiveSheet: Int, Identifiable { case settings, history, plan, goal; var id: Int { rawValue } }
    @State private var activeSheet: ActiveSheet?
    /// The coach's avatar diameter beside its bubbles and in the typing indicator (#R-bigger-avatar) — one
    /// named constant instead of a magic number repeated at every call site, since the gutter spacer
    /// (`assistantGutter`) and the evidence/actionRow indent below a reply both have to match it exactly.
    private static let assistantAvatarSize: CGFloat = 36
    /// Vertical gap before a NEW turn (a role switch, or the first message) — bigger, so a fresh reply or
    /// question reads as its own moment (#R-chat-tidy). Also used before the typing indicator/error banner,
    /// which are themselves always the start of a new turn.
    private static let groupGap: CGFloat = 16
    /// Vertical gap before a CONTINUATION bubble — the same sender following themselves, tight so a run of
    /// coach turns still reads as one thought rather than several unrelated ones.
    private static let continuationGap: CGFloat = 4
    /// The ONE extra indent step for content nested a level deeper than a reply's side content (evidence
    /// header, Regenerate, actionRow all sit flush with each other; the expanded evidence detail sits one
    /// `sideContentIndent` in from that) — previously three uneven levels (#R-chat-tidy).
    private static let sideContentIndent: CGFloat = 14
    /// Which messages' evidence chains (P6) are expanded — per-message, so opening one doesn't open
    /// every reply that has one.
    @State private var expandedEvidenceIds: Set<UUID> = []
    /// First-run goal onboarding (offered once, skippable — see the `.task` that arms it).
    @State private var showGoalOnboarding = false
    /// First-use trust/expectations note (#P6 6.3): shown once before the first conversation.
    @AppStorage(CoachFirstUse.acknowledgedKey) private var coachFirstUseAcknowledged = false
    @State private var showFirstUse = false
    /// Drives the header's pending-proposal dot.
    @ObservedObject private var planStore = CoachPlanStore.shared
    /// The coach's identity (#R9) — avatar + name shown in the header, updated live from settings.
    @ObservedObject private var identityStore = CoachIdentityStore.shared
    /// Live Sessions (silent guardian) beta gate — the SAME key `LiquidTodayView`/Settings read. Hides
    /// the action row's "Live Session" chip when the user has turned the feature off, so the chip never
    /// looks tappable for something it can't actually open (#P3).
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
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
            case .goal:
                // The chat's goal shortcut (#R6): the same Goal & Journey surface reachable from the
                // top-level menu, presented over the chat with its own Done control.
                NavigationStack {
                    CoachGoalJourneyScreen()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { activeSheet = nil } }
                        }
                }
                .environmentObject(coach)
            }
        }
        .task(id: coach.dataConsent) {
            // On open: the morning brief (forward), then — sequentially, each with its own once-per-day
            // or once-per-week lock and a real-signal gate — a proactive nudge and a weekly review (#P10).
            // In practice the latter two stay silent most days; they only speak on a streak, a run of
            // skips, or once a week. Sequential so two auto-messages never race the `sending` flag.
            await coach.startBriefIfNeeded()
            await coach.runProactiveNudgeIfNeeded()
            await coach.runWeeklyReviewIfNeeded()
        }
        // Tapping the daily check-in notification (routed here by RootTabView) runs a real check-in —
        // a look BACK at what happened, not a re-run of the morning brief. Its own once-a-day lock.
        .onReceive(NotificationCenter.default.publisher(for: .noopOpenCoachCheckIn)) { _ in
            Task { await coach.checkInIfNeeded() }
        }
        // Opened from a metric card (#P11): read the pending card context and give a short, cheap read of
        // that one metric, then offer its follow-up questions. No-op if the coach was opened another way.
        // Fires two ways so both cases are covered, and is idempotent (it clears the pending context and
        // no-ops when nil): the notification catches an ALREADY-mounted CoachView (the iOS tab that's up),
        // and the .task catches a JUST-mounted one (a fresh Coach pane on macOS, opened by the same tap).
        .onReceive(NotificationCenter.default.publisher(for: .noopOpenCoachCard)) { _ in
            Task { await coach.runCardAnalysisIfNeeded() }
        }
        .task {
            if coach.pendingCardContext != nil { await coach.runCardAnalysisIfNeeded() }
        }
        // First-use note (#P6 6.3): once the coach is connected, show the trust/expectations dialog
        // before the first conversation. Keyed on `isConfigured` so it also arms right after the user
        // connects from the setup screen (not just on a fresh, already-connected open).
        .task(id: coach.isConfigured) {
            if coach.isConfigured && !coachFirstUseAcknowledged { showFirstUse = true }
        }
        .sheet(isPresented: $showFirstUse) {
            CoachFirstUseSheet(onAcknowledge: {
                coachFirstUseAcknowledged = true
                showFirstUse = false
            })
            .environmentObject(coach)
        }
        // Goal onboarding: offered ONCE, only to a configured coach with no goal yet, and skippable.
        // Gated behind the first-use ack too, so the two one-time sheets never stack — goal onboarding
        // simply waits for the next open after the note is acknowledged. The flag is set whichever way
        // the sheet closes, so declining is respected permanently — you can always set a goal later.
        .task {
            guard coach.isConfigured,
                  coachFirstUseAcknowledged,
                  CoachGoalStore.shared.activeGoals.isEmpty,
                  !UserDefaults.standard.bool(forKey: Self.goalOnboardingAskedKey) else { return }
            showGoalOnboarding = true
        }
        .sheet(isPresented: $showGoalOnboarding) {
            // First-run onboarding now uses the GUIDED flow (#R12) — one question at a time — instead of
            // the one-page editor. Skipping or finishing both mark it asked, so it never nags twice.
            CoachGoalOnboardingFlow {
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

            HStack(spacing: 8) {
                // The coach's IDENTITY (#R9): its chosen avatar (a design-system mark or the user's photo)
                // + its name, so the chat has a consistent face and self — Svea, Marv, or a custom coach —
                // not a generic "Coach". A named conversation takes the title slot; the avatar stays either
                // way. (The behavioural STYLE lives on `coach.persona`, a separate axis.)
                CoachAvatarView(size: 26)
                VStack(spacing: 1) {
                    // The identity name is the user's own free text (like the conversation title) — shown
                    // as-is, no catalog lookup needed.
                    Text(coach.activeConversation?.title.isEmpty == false
                         ? coach.activeConversation!.title
                         : identityStore.identity.name)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    if coach.sending {
                        Text("Thinking…")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(coach.activeConversation?.title.isEmpty == false
                                 ? coach.activeConversation!.title
                                 : String(localized: "\(identityStore.identity.name), your coach"))

            HStack(spacing: 14) {
                // The plan book. The dot means something is waiting for YOUR answer — the coach can
                // propose, but only you can turn a suggestion into a plan.
                // Goal & Journey shortcut (#R6) — one tap to the goal surface from the chat, alongside
                // the plan book, instead of digging through settings.
                Button { activeSheet = .goal } label: {
                    Image(systemName: "target")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Goal and journey")

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
                LazyVStack(alignment: .leading, spacing: 0) {
                    if coach.messages.isEmpty {
                        emptyState
                    }
                    ForEach(Array(coach.messages.enumerated()), id: \.element.id) { index, message in
                        if shouldShowTimestamp(at: index) {
                            timeSeparator(message.date)
                        }
                        bubble(message, groupStart: isAssistantGroupStart(at: index))
                            .id(message.id)
                            .padding(.top, topGap(at: index))
                    }
                    if coach.sending {
                        typingIndicator.id("typing").padding(.top, Self.groupGap)
                    }
                    if let error = coach.errorText, !error.isEmpty {
                        errorBanner(error).id("error").padding(.top, Self.groupGap)
                    }
                    // Suggestion chips live at the bottom of an empty transcript, just above the composer.
                    if coach.messages.isEmpty {
                        suggestionChips.padding(.top, 4)
                    } else if !coach.cardSuggestions.isEmpty {
                        // After a card read (#P11): metric-specific follow-ups, offered until the next turn.
                        cardSuggestionChips.padding(.top, 4)
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

    /// True when this assistant message opens a run of consecutive coach turns — messenger-style, the
    /// avatar shows once at the top of a group and continuation bubbles reserve the gutter to stay aligned.
    private func isAssistantGroupStart(at index: Int) -> Bool {
        let msgs = coach.messages
        guard index >= 0, index < msgs.count, msgs[index].role == .assistant else { return false }
        return index == 0 || msgs[index - 1].role != .assistant
    }

    /// The vertical gap ABOVE the message at `index` (#R-chat-tidy): a bigger `groupGap` for a new turn
    /// (the first message, a role switch, or two consecutive user sends — there's no "continuation" concept
    /// for the user side), a tight `continuationGap` only when both this message and the one before it are
    /// coach replies in the same run (mirrors `isAssistantGroupStart`'s own same-role check).
    private func topGap(at index: Int) -> CGFloat {
        guard index > 0, index < coach.messages.count else { return 0 }
        let cur = coach.messages[index].role
        let prev = coach.messages[index - 1].role
        return (cur == .assistant && prev == .assistant) ? Self.continuationGap : Self.groupGap
    }

    /// The leading avatar (or an equal-width empty gutter for continuation turns), so coach bubbles line up
    /// under one avatar the way a messenger thread does (#R10). Sized to sit beside the bubble's first line.
    @ViewBuilder
    private func assistantGutter(groupStart: Bool) -> some View {
        if groupStart {
            CoachAvatarView(size: Self.assistantAvatarSize)
        } else {
            Color.clear.frame(width: Self.assistantAvatarSize, height: 1)
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage, groupStart: Bool = false) -> some View {
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
                HStack(alignment: .top, spacing: 8) {
                    assistantGutter(groupStart: groupStart)
                    CoachChartBubble(artifact: chart)
                    Spacer(minLength: 0)
                }
            } else if !message.text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        assistantGutter(groupStart: groupStart)
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

                    // The evidence chain and action controls sit UNDER the bubble, so they carry the same
                    // leading gutter (avatar width + spacing) the bubble does — they line up with the coach's
                    // text, not with the avatar (#R10).
                    VStack(alignment: .leading, spacing: 4) {
                        evidenceChain(for: message)

                        // Visible, not just a long-press away — the context menu above still works too.
                        if isLastAssistant(message) {
                            Button { coach.regenerate() } label: {
                                Label("Regenerate", systemImage: "arrow.clockwise")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .disabled(coach.sending)
                            .accessibilityLabel("Regenerate this reply")

                            actionRow
                        }
                    }
                    .padding(.leading, Self.assistantAvatarSize + 8)
                }
            }
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button { CoachClipboard.copy(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
    }

    // MARK: - Evidence chain (P6): what actually grounded this reply

    /// A short, human label per tool for the evidence list. Written as a switch of literal `Text(...)`
    /// calls (not a computed `String` on `CoachTool`) for the same scanner-visibility reason as the
    /// settings hub's row titles — piping this through a property would make it invisible to
    /// `Tools/i18n_audit.py`. Several cases intentionally share one literal ("Memory" for all three
    /// memory-editing tools) — one catalog entry, not three near-duplicates.
    @ViewBuilder
    private func evidenceLabel(_ tool: CoachTool) -> some View {
        switch tool {
        case .biometricSummary:        Text("Your metrics")
        case .recentWorkouts:          Text("Recent workouts")
        case .stressIndex:             Text("Stress index")
        case .personalPatterns:        Text("Your patterns")
        case .plotMetric:              Text("Chart")
        case .rememberFact, .updateFact, .forgetFact: Text("Memory")
        case .searchPastConversations: Text("Past conversations")
        case .logCaffeine:             Text("Caffeine log")
        case .logJournal:              Text("Journal")
        case .logLabMarker:            Text("Lab Book")
        case .sleepDetail:             Text("Sleep detail")
        case .rangeReport:             Text("Range report")
        case .readiness:               Text("Readiness")
        case .chargeDrivers:           Text("Charge breakdown")
        case .proposePlan:             Text("Plan proposal")
        case .sessionOutlook:          Text("Session outlook")
        case .simulateDay:             Text("Simulation")
        case .planAdherence:           Text("Plan adherence")
        case .myLogs:                  Text("Your logs")
        case .zoneMinutes:             Text("Zone minutes")
        }
    }

    /// A one-line "what this source contributed" note per tool (#P12 12.2) — the data BEHIND the label, so
    /// the evidence chain reads as reasoning ("grounded in your recovery + HRV"), not a bare tool name or a
    /// raw-data dump. Same literal-`Text` switch as `evidenceLabel` for i18n-scanner visibility.
    @ViewBuilder
    private func evidenceDetail(_ tool: CoachTool) -> some View {
        switch tool {
        case .biometricSummary:        Text("Recovery, HRV, resting HR and sleep")
        case .recentWorkouts:          Text("Your last few sessions and their strain")
        case .stressIndex:             Text("Autonomic load from today's heart-rate variability")
        case .personalPatterns:        Text("Your own strongest n-of-1 correlations")
        case .plotMetric:              Text("A metric plotted over time")
        case .rememberFact, .updateFact, .forgetFact: Text("Facts you've asked the coach to keep")
        case .searchPastConversations: Text("Earlier things you discussed")
        case .logCaffeine:             Text("Caffeine you logged")
        case .logJournal:              Text("A journal note you logged")
        case .logLabMarker:            Text("A lab marker you logged")
        case .sleepDetail:             Text("Last night's stages, timing and debt")
        case .rangeReport:             Text("Trends across a range of weeks or months")
        case .readiness:               Text("Today's push / maintain / rest call")
        case .chargeDrivers:           Text("What moved your Charge up or down")
        case .proposePlan:             Text("A session proposed for you to accept or change")
        case .sessionOutlook:          Text("What a session would cost, from your history")
        case .simulateDay:             Text("Tomorrow's Charge under a plan")
        case .planAdherence:           Text("How closely you've kept to your plan")
        case .myLogs:                  Text("What you logged — caffeine, journal, lab, mood")
        case .zoneMinutes:             Text("Time spent in each heart-rate zone")
        }
    }

    /// Expandable per-message evidence — which tools actually backed this specific reply, and hence
    /// which of the user's own data it's grounded in. The tool loop already knows this (`toolsUsed` on
    /// the message); this is purely a disclosure, not new computation. Empty for replies from a
    /// non-tool-calling provider, matching `toolsUsed`'s own emptiness there.
    @ViewBuilder
    private func evidenceChain(for message: ChatMessage) -> some View {
        let tools = ChatMessage.uniqueTools(from: message.toolsUsed)
        if !tools.isEmpty {
            let isExpanded = expandedEvidenceIds.contains(message.id)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(StrandMotion.fade) {
                        if isExpanded { expandedEvidenceIds.remove(message.id) }
                        else { expandedEvidenceIds.insert(message.id) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal")
                            .accessibilityHidden(true)
                        // Source count sits in the collapsed header (#P12 12.1) so the ground is VISIBLE
                        // without expanding — "grounded in 3 of your sources", not a mystery until tapped.
                        Text("Grounded in \(tools.count) of your data sources")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .accessibilityHidden(true)
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide what grounded this answer" : "Show what grounded this answer")

                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tools, id: \.self) { tool in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 3))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    // The source, then what it actually contributed (#P12 12.2): a label a
                                    // user can read, plus the data behind it — reasoning, not a raw dump.
                                    evidenceLabel(tool)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                    evidenceDetail(tool)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                            .font(StrandFont.caption)
                        }
                    }
                    .padding(.leading, Self.sideContentIndent)
                }
            }
        }
    }

    // MARK: - Action row (P6): advice → action without a navigation break

    /// Three one-tap hops to common next steps after coaching advice, under the LAST reply only (like
    /// Regenerate) so the transcript doesn't accumulate a row under every message. Not content-triggered
    /// (the reply text isn't scanned for "you should breathe" etc.) — guessing intent from prose is
    /// fragile; these are just the standing fast paths from advice to doing something about it.
    private var actionRow: some View {
        HStack(spacing: 8) {
            // Each title is a literal `Text(...)` at its own call site (not a `String` routed through
            // `actionChip`'s parameter) — the same scanner-visibility reason as `evidenceLabel` above.
            actionChip(icon: "wind", action: { navRouter.openBreathe() }) { Text("Breathe") }
            // Hidden when the user turned Live Sessions off (Settings/Today's own toggle) — the chip
            // would otherwise look tappable for a feature it can't actually open (#P3).
            if liveSessionsBeta {
                actionChip(icon: "waveform.path.ecg", action: { navRouter.openLiveSession() }) { Text("Live Session") }
            }
            actionChip(icon: "calendar.badge.plus", action: { activeSheet = .plan }) { Text("Schedule a session") }
        }
        .padding(.top, 2)
    }

    private func actionChip<Content: View>(
        icon: String, action: @escaping () -> Void, @ViewBuilder label: () -> Content
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).accessibilityHidden(true)
                label()
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var typingIndicator: some View {
        HStack(alignment: .top, spacing: 8) {
            CoachAvatarView(size: Self.assistantAvatarSize)
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
        }
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

    /// Follow-up chips offered right after a card read (#P11 11.3), styled like `suggestionChips` but fed
    /// from the engine's `cardSuggestions` (metric-specific) rather than the fixed starter set.
    private var cardSuggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(coach.cardSuggestions, id: \.self) { prompt in
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
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                    .strokeBorder(composerFocused ? StrandPalette.focusRing : StrandPalette.hairline, lineWidth: 1))
                // Tap-to-focus must cover the whole visible bar, not just the TextField's own tight
                // glyph-rendering rect (#R1) — without an explicit shape here, the hit area follows the
                // pre-padding geometry, so most of what reads as "the input bar" doesn't focus it and a
                // tap can silently miss (worst near the trailing/vertical edges of the padded field).
                .contentShape(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                .focused($composerFocused)
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
