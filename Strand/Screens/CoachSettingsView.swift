import SwiftUI
import StrandDesign

/// Everything that configures Coach, moved out of the chat so the conversation stays clean: provider /
/// key / model setup, the data-consent opt-ins, coaching persona, daily check-in, persistent memory,
/// and the editable system prompt. Presented as a sheet from the chat's gear button.
///
/// Bindings are the same `AICoachEngine` properties the old inline cards used — only relocated, not
/// rewired. Design-system tokens only, per `docs/CONTRIBUTING.md`.
struct CoachSettingsView: View {
    @EnvironmentObject var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss

    /// Pending key text (never persisted here, handed to `setKey`).
    @State private var keyDraft: String = ""
    @State private var customModel: Bool = false
    @State private var customModelDraft: String = ""
    @State private var promptExpanded: Bool = false
    @State private var promptDraft: String = ""
    /// Presents the searchable model sheet — only reachable once a provider's list exceeds
    /// `searchableModelThreshold` (today just OpenRouter).
    @State private var showModelSearch = false
    @State private var checkInOn: Bool = CoachCheckIn.isEnabled
    @State private var checkInTime: Date = CoachCheckIn.timeAsDate
    @State private var checkInDenied: Bool = false
    @State private var planReminderOn: Bool = PlanReminder.isEnabled
    @State private var planReminderDenied: Bool = false

    // MARK: Hub attention badges

    /// A blank model is the one "configured yet still broken" state reachable from the hub: Custom can
    /// be `isConfigured` (a base URL was saved) with no model chosen, and `send()` would otherwise be the
    /// first place this surfaces (as an opaque 400 further down the line).
    private var connectionNeedsAttention: Bool {
        coach.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An active goal whose date has passed — the same condition `expiredGoalCard` acts on — is exactly
    /// the state B2 gave a decision UI to; the badge is what tells you it's waiting.
    private var goalNeedsAttention: Bool {
        guard let g = goalStore.goal, g.status == .active, let weeks = g.weeksRemaining() else { return false }
        return weeks < 0
    }

    /// The daily check-in LOOKS on but silently never fires once notification authorization is revoked
    /// (in iOS Settings, outside the app) — `checkInDenied` alone only catches a denial from THIS
    /// session's toggle; `refreshCheckInAuthorization` below also catches a revocation from any time.
    private var coachingNeedsAttention: Bool { checkInOn && checkInDenied }

    /// Re-check authorization whenever the Coaching subpage appears, so a permission revoked in iOS
    /// Settings since the toggle was last touched still surfaces as "needs attention" instead of staying
    /// silently broken.
    private func refreshCheckInAuthorization() async {
        guard checkInOn else { return }
        checkInDenied = await !CoachCheckIn.isCurrentlyAuthorized()
    }
    @ObservedObject private var memory = CoachMemory.shared
    /// The structured goal (P3). The memory card's field still edits its title inline; the full editor
    /// with target/date/pace lives in the dedicated goal card.
    @ObservedObject private var goalStore = CoachGoalStore.shared
    @ObservedObject private var usage = CoachUsageLog.shared
    @State private var memoryExpanded: Bool = false
    /// How the user reaches Coach from Today: the card, the draggable floating button, or both.
    @AppStorage(CoachEntryMode.storageKey) private var coachEntryModeRaw = CoachEntryMode.both.rawValue
    /// Opt-in: opening Today on a new day generates a workout suggestion. Same key MorningSuggestionCard
    /// reads. Default OFF — a Today-triggered generation is the one thing that talks to the network on
    /// open, so it must be chosen.
    @AppStorage("coach.morningSuggestion") private var morningSuggestionOn = false
    /// Which corner the floating button is pinned to (`.custom` once dragged), and whether it's locked.
    @AppStorage(CoachButtonCorner.storageKey) private var fabCornerRaw = CoachButtonCorner.bottomTrailing.rawValue
    @AppStorage(CoachButtonCorner.lockedKey) private var fabLocked = false
    /// In-place fact editing: the fact being edited + its working text.
    @State private var editingFactID: UUID?
    @State private var editingFactText: String = ""
    /// Presents the structured goal editor.
    @State private var showGoalEditor = false
    @State private var showNewGoalEditor = false
    @State private var showSetAsideDialog = false
    @State private var showDeleteGoalConfirm = false
    /// Presents the Journey page (progress, milestones, plan history) — only reachable once a goal exists.
    @State private var showJourney = false

    private let customModelTag = "__custom__"

    var body: some View {
        NavigationStack {
            Group {
                if coach.isConfigured {
                    hub
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            setupCard
                            privacyFootnote
                        }
                        .padding(16)
                    }
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                }
            }
            // Drop an explicit "Custom…" pick made on the OLD provider — otherwise `customModel` stays
            // true after switching away and forces the free-text field open even though the new
            // provider's model list is perfectly valid. `isCustomModelSelected` still catches the new
            // provider's own empty-list moment on its own.
            //
            // Single-param closure, not the two-param `{ _, _ in }` form: this view is shared with the
            // macOS `Strand` target (deploymentTarget 13.0 in project.yml), and that form needs macOS 14
            // (see ScreenScaffold.swift's `#if os(iOS)` guard around its own two-param onChange).
            .onChange(of: coach.provider) { _ in customModel = false }
            .navigationTitle("Coach settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Edit fact", isPresented: editingBinding) {
                TextField("Fact", text: $editingFactText)
                Button("Cancel", role: .cancel) { editingFactID = nil }
                Button("Save") {
                    if let id = editingFactID { memory.update(id, text: editingFactText) }
                    editingFactID = nil
                }
            }
        }
    }

    /// Drives the edit-fact alert from `editingFactID` without a separate bool.
    private var editingBinding: Binding<Bool> {
        Binding(get: { editingFactID != nil }, set: { if !$0 { editingFactID = nil } })
    }

    // MARK: - Hub

    /// The configured-state landing page: the status pill, then five rows drilling into their own
    /// subpages. Used to be one scroll of 11 stacked cards; every card below is UNCHANGED — only which
    /// page it lives on moved. Titles/subtitles are written as literal `Text(...)` calls (not routed
    /// through a shared `title: String` helper parameter) on purpose: `Tools/i18n_audit.py` only
    /// recognises a translatable string when it's a literal argument directly at a `Text(`/
    /// `.navigationTitle(` call site — piping it through a variable first would make these 10 new
    /// strings invisible to the very gate that just closed 27 identical gaps fork-wide (M1).
    private var hub: some View {
        ScrollView {
            VStack(spacing: 16) {
                connectedHeader

                NavigationLink { connectionSubpage } label: {
                    NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Connection & model")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("Provider, API key and which model answers.")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            attentionBadge(connectionNeedsAttention)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(connectionNeedsAttention ? "Needs attention" : "")

                NavigationLink { goalJourneySubpage } label: {
                    NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                        HStack(spacing: 10) {
                            Image(systemName: "target")
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Goal & Journey")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("Set a target and see your progress.")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            attentionBadge(goalNeedsAttention)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(goalNeedsAttention ? "Needs attention" : "")

                NavigationLink { coachingSubpage } label: {
                    NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                        HStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Coaching")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("Style, how you open Coach, and daily check-ins.")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            attentionBadge(coachingNeedsAttention)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(coachingNeedsAttention ? "Needs attention" : "")

                NavigationLink { memorySubpage } label: {
                    NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                        HStack(spacing: 10) {
                            Image(systemName: "brain")
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Memory")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("What the coach remembers, and chat summaries.")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)

                NavigationLink { privacySubpage } label: {
                    NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Privacy & data")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("What's shared, and the coach's instructions.")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)

                privacyFootnote
            }
            .padding(16)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    /// A small dot on a hub row when something on its subpage needs the user's attention — computed
    /// fresh each render from state already loaded for the row, no separate persistence. The row's own
    /// `.accessibilityValue` carries the same signal for VoiceOver, since a dot alone is purely visual.
    @ViewBuilder
    private func attentionBadge(_ needsAttention: Bool) -> some View {
        if needsAttention {
            Circle()
                .fill(StrandPalette.statusWarning)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
    }

    /// Shared scroll/padding/background scaffold for a subpage. Deliberately takes NO title parameter —
    /// each subpage applies its own literal `.navigationTitle("...")` outside this wrapper, for the same
    /// scanner-visibility reason as the hub rows above.
    private func subpageScaffold<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 16) { content() }
                .padding(16)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Provider, key, model, token usage, disconnect. Was reachable only by first tapping Disconnect —
    /// `providerConfigFields` now lives here too so switching provider or model doesn't require that.
    private var connectionSubpage: some View {
        subpageScaffold {
            providerConfigFields
            tokenUsageBar
            disconnectRow
        }
        .navigationTitle("Connection & model")
    }

    /// `goalBar` already carries its own sheets for the goal editor and Journey — unchanged, just relocated.
    /// A passed target date surfaces as a decision card here, not a dead-end footnote.
    private var goalJourneySubpage: some View {
        subpageScaffold {
            expiredGoalCard
            goalBar
        }
        .navigationTitle("Goal & Journey")
    }

    private var coachingSubpage: some View {
        subpageScaffold {
            personaBar
            coachEntryBar
            morningSuggestionBar
            checkInBar
            planReminderBar
        }
        .navigationTitle("Coaching")
        .task { await refreshCheckInAuthorization() }
    }

    private var memorySubpage: some View {
        subpageScaffold {
            memoryBar
            if coach.dataConsent { memoryMaintenanceBar }
        }
        .navigationTitle("Memory")
    }

    private var privacySubpage: some View {
        subpageScaffold {
            consentBar
            if coach.dataConsent { onDeviceSignalsBar }
            systemPromptBar
        }
        .navigationTitle("Privacy & data")
    }

    // MARK: - Coach entry preference (iOS: card vs. draggable floating button vs. both)

    @ViewBuilder private var coachEntryBar: some View {
        #if os(iOS)
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Coach entry")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("How you open Coach from Today — a card, a draggable floating button, or both.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                Picker("Coach entry", selection: $coachEntryModeRaw) {
                    ForEach(CoachEntryMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Coach entry style")

                // Button placement only matters when the floating button is actually shown.
                if (CoachEntryMode(rawValue: coachEntryModeRaw) ?? .both).showsButton {
                    Divider().overlay(StrandPalette.hairline)
                    buttonPlacementControls
                }
            }
        }
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    /// Pin the floating button to one of four chrome-clear corners, or lock it where it is. Four tappable
    /// icons rather than a Picker: a segmented Picker can't show "no corner selected" for a dragged button.
    @ViewBuilder private var buttonPlacementControls: some View {
        let corner = CoachButtonCorner(rawValue: fabCornerRaw) ?? .bottomTrailing
        VStack(alignment: .leading, spacing: 8) {
            Text("Button position").strandOverline()
            HStack(spacing: 8) {
                ForEach(CoachButtonCorner.pickable) { c in
                    let active = c == corner
                    Button {
                        withAnimation(StrandMotion.interactive) { fabCornerRaw = c.rawValue }
                    } label: {
                        Image(systemName: c.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(active ? .white : StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                                    .fill(active ? StrandPalette.accent : StrandPalette.surfaceInset)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                                    .strokeBorder(StrandPalette.hairline, lineWidth: active ? 0 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.label)
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                }
            }
            Text(corner == .custom
                 ? "Dragged freely — tap a corner to pin it. Corners stay clear of the tab bar and header."
                 : "Pinned: \(corner.label). Drag the button anytime to place it freely.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $fabLocked) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lock position")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Stops the button moving if you brush it. Tapping still opens Coach.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(StrandPalette.accent)
        }
    }
    #endif

    // MARK: - Memory maintenance (cheap-model summaries)

    private var memoryMaintenanceBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(coach.autoSummarize ? StrandPalette.accent : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Summarise past chats")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(coach.autoSummarize
                             ? "On: when you move on from a chat, a cheap model distils it so the coach remembers it later. Sends that chat to your provider."
                             : "Off: past chats aren't summarised; the coach only recalls saved facts.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $coach.autoSummarize)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Summarise past chats automatically")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Memory model").strandOverline()
                    TextField(coach.provider.cheapModel.isEmpty ? "Same as coaching model" : coach.provider.cheapModel,
                              text: $coach.memoryModel)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .disableAutocorrection(true)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .accessibilityLabel("Memory model id")
                    Text("The cheap, fast model used only for memory upkeep — keep it small to stay cheap.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button {
                        if let id = coach.activeConversationID { coach.summarizeNow(id) }
                    } label: {
                        Label("Summarise this chat now", systemImage: "sparkles")
                            .font(StrandFont.footnote).labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityLabel("Summarise the current chat now")
                }
            }
        }
    }

    // MARK: - Token usage (last question)

    /// What the last question actually cost, and whether prompt caching engaged. Shown only once a
    /// question has been asked and only for providers that report token counts — an empty card would
    /// just be noise.
    ///
    /// This is deliberately visible rather than a hidden debug flag: Anthropic's cache needs the cached
    /// part of the request to clear a minimum length that varies by model, and under it the cache does
    /// nothing at all without reporting anything. This card is the only place that shows which of the two
    /// is happening.
    @ViewBuilder
    private var tokenUsageBar: some View {
        if let turn = usage.lastTurn, !turn.rounds.isEmpty {
            let cached = turn.cacheReadTokens > 0
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        // Icon AND word — never colour alone.
                        Image(systemName: cached ? "bolt.fill" : "bolt.slash")
                            .foregroundStyle(cached ? StrandPalette.accent : StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        Text("Last question")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 8)
                        StatePill(cached ? "Cached" : "Uncached", tone: cached ? .accent : .neutral)
                    }

                    Text(CoachUsageLog.summaryLine(for: turn))
                        .font(StrandFont.footnote.monospacedDigit())
                        .foregroundStyle(StrandPalette.textSecondary)

                    Text(CoachUsageLog.cacheVerdict(for: turn))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Last question token usage. "
                                    + CoachUsageLog.summaryLine(for: turn) + ". "
                                    + CoachUsageLog.cacheVerdict(for: turn))
            }
        }
    }

    // MARK: - Connected summary + disconnect

    private var connectedHeader: some View {
        HStack(spacing: 10) {
            StatePill("\(coach.provider.displayName) · \(coach.model)", tone: .accent, showsDot: true)
            Spacer()
        }
    }

    private var disconnectRow: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                coach.disconnect()
                keyDraft = ""
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
                    .font(StrandFont.subhead)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.statusCritical)
            .accessibilityLabel("Disconnect provider")
        }
    }

    // MARK: - Consent

    private var consentBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.dataConsent ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(coach.dataConsent ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Let the coach use my data")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.dataConsent
                         ? "On: your charge, rest, HRV and workouts are shared with the provider for tailored coaching."
                         : "Off: the coach answers generally and sends none of your metrics.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.dataConsent)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Let the coach use my data")
            }
        }
    }

    private var onDeviceSignalsBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.includeOnDeviceSignals ? "checklist.checked" : "checklist")
                    .foregroundStyle(coach.includeOnDeviceSignals ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Also share my patterns & Lab Book")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.includeOnDeviceSignals
                         ? "On: a short summary of your strongest patterns and logged health numbers is added. Summaries only, never raw readings."
                         : "Off: only your core metrics are shared, not your patterns or Lab Book.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.includeOnDeviceSignals)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Also share my patterns and Lab Book with the coach")
            }
        }
    }

    // MARK: - Persona

    private var personaBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: coach.persona.symbol)
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Coaching style")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(coach.persona.subtitle)
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                Picker("Coaching style", selection: Binding(
                    get: { coach.persona },
                    set: { coach.persona = $0 }
                )) {
                    ForEach(CoachPersona.allCases) { p in
                        Text(p.title).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel("Coaching style")
            }
        }
    }

    // MARK: - Morning suggestion (Today-triggered)

    /// A plain opt-in toggle, NOT a `CoachCheckIn.setEnabled` case: no notification authorization is
    /// involved (the generation happens on open, foreground), so there's no `.denied` outcome and no
    /// async gate. Gated on a configured coach with data consent, so the card never has to render a
    /// "no key" state.
    private var morningSuggestionBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: morningSuggestionOn ? "sun.max.fill" : "sun.max")
                        .foregroundStyle(morningSuggestionOn ? StrandPalette.accent : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Morning suggestion on Today")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(morningSuggestionOn
                             ? "On: opening Today generates one workout suggestion a day to accept, change or decline."
                             : "Off: the coach suggests a session only when you ask in chat.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $morningSuggestionOn)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Morning suggestion on Today")
                }
                if !(coach.isConfigured && coach.dataConsent) {
                    Text("Needs a connected provider and data access, so the coach has something to suggest from.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(!(coach.isConfigured && coach.dataConsent))
    }

    // MARK: - Daily check-in

    private var checkInBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: checkInOn ? "bell.badge.fill" : "bell")
                        .foregroundStyle(checkInOn ? StrandPalette.accent : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Daily check-in")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(checkInOn
                             ? "On: a daily reminder to open your coaching brief."
                             : "Off: the coach only responds when you ask.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $checkInOn)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Daily coach check-in")
                        .onChangeCompat(of: checkInOn) { on in
                            CoachCheckIn.setEnabled(on) { outcome in
                                if outcome == .denied {
                                    checkInOn = false
                                    checkInDenied = true
                                } else {
                                    checkInDenied = false
                                }
                            }
                        }
                }
                if checkInOn {
                    HStack {
                        Text("Time").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 8)
                        DatePicker("Check-in time", selection: $checkInTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .onChangeCompat(of: checkInTime) { newValue in
                                CoachCheckIn.setTime(from: newValue)
                            }
                            .accessibilityLabel("Check-in time")
                    }
                }
                if checkInDenied {
                    Text("Notifications are off. Enable them for NOOP in Settings to use check-ins.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.recovery000)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Opt-in local reminder for a committed, timed plan session — "a plan with a time is a plan you
    /// keep", made real. On-device only; no AI call fires it, and no notification exists until a session
    /// actually has a time (`PlanReminder.schedule` no-ops otherwise).
    private var planReminderBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: planReminderOn ? "bell.badge.fill" : "bell")
                        .foregroundStyle(planReminderOn ? StrandPalette.accent : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Plan reminders")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(planReminderOn
                             ? "On: a reminder at the time you set for a planned session."
                             : "Off: sessions with a time don't remind you.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $planReminderOn)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Plan session reminders")
                        .onChangeCompat(of: planReminderOn) { on in
                            PlanReminder.setEnabled(on) { outcome in
                                if outcome == .denied {
                                    planReminderOn = false
                                    planReminderDenied = true
                                } else {
                                    planReminderDenied = false
                                }
                            }
                        }
                }
                if planReminderDenied {
                    Text("Notifications are off. Enable them for NOOP in Settings to use reminders.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.recovery000)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Goal

    /// The structured goal, summarised with the arithmetic already done (weeks left, pace verdict) —
    /// tapping opens the full editor. Shows an invitation rather than an empty field when unset, since
    /// a goal is entirely optional and NOOP works fine without one.
    /// True once the goal has been closed either way — the bar then offers a fresh start, not an edit.
    private var goalIsClosed: Bool {
        goalStore.goal?.status == .achieved || goalStore.goal?.status == .abandoned
    }

    private var goalBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    if goalIsClosed { showNewGoalEditor = true } else { showGoalEditor = true }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: goalStore.goal?.status == .achieved ? "checkmark.seal.fill" : "target")
                            .foregroundStyle(goalStore.goal == nil ? StrandPalette.textTertiary : StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(goalStore.goal?.title.isEmpty == false ? goalStore.goal!.title : "Set a goal")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                            Text(goalSubtitle)
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(goalStore.goal == nil ? "Set a goal"
                                    : (goalIsClosed ? "Set a new goal" : "Edit your goal"))

                if goalStore.goal != nil {
                    Divider().overlay(StrandPalette.hairline)
                    Button { showJourney = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                            Text("View your journey")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View your goal journey — progress, milestones and plan history")

                    Divider().overlay(StrandPalette.hairline)
                    goalLifecycleRow
                }
            }
        }
        .sheet(isPresented: $showGoalEditor) { CoachGoalEditorView(isOnboarding: false) }
        .sheet(isPresented: $showNewGoalEditor) { CoachGoalEditorView(isOnboarding: false, startsFresh: true) }
        .sheet(isPresented: $showJourney) { JourneyView().environmentObject(coach) }
        .confirmationDialog("Set this goal aside?", isPresented: $showSetAsideDialog, titleVisibility: .visible) {
            Button("Injury or health") { goalStore.setAside(reason: "injury or health") }
            Button("Life got busy") { goalStore.setAside(reason: "life got busy") }
            Button("Priorities changed") { goalStore.setAside(reason: "priorities changed") }
            Button("No particular reason") { goalStore.setAside(reason: "") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays in your history — nothing is lost, and there's nothing to justify.")
        }
        .confirmationDialog("Delete this goal?", isPresented: $showDeleteGoalConfirm, titleVisibility: .visible) {
            Button("Delete goal", role: .destructive) { goalStore.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the goal and its history from the device. There is no undo.")
        }
    }

    /// A goal must be able to END: close it as reached, set it aside, or delete it entirely.
    /// Before this row existed, `save()` forcing `.active` meant a goal could only ever be edited.
    private var goalLifecycleRow: some View {
        HStack(spacing: 16) {
            if goalStore.goal?.status == .active || goalStore.goal?.status == .paused {
                Button("Mark as achieved") { goalStore.markAchieved() }
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                Button("Set aside") { showSetAsideDialog = true }
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            } else {
                Button("Set a new goal") { showNewGoalEditor = true }
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
            }
            Spacer(minLength: 8)
            Button { showDeleteGoalConfirm = true } label: {
                Image(systemName: "trash")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
            }
            .accessibilityLabel("Delete goal")
        }
        .buttonStyle(.plain)
    }

    /// The passed-date decision card: reached, more time, or set aside — a fork, not a dead end.
    /// Only an ACTIVE goal with a passed date needs deciding; closed goals already have their answer.
    @ViewBuilder
    private var expiredGoalCard: some View {
        if let g = goalStore.goal, g.status == .active, let weeks = g.weeksRemaining(), weeks < 0 {
            NoopCard(padding: 14, tint: StrandPalette.statusWarning) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityHidden(true)
                        Text("Your target date has passed")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text("How did it go? Close it out, give it more time, or set it aside — your call.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button("I reached it") { goalStore.markAchieved() }
                            .foregroundStyle(StrandPalette.accent)
                        Button("Extend the date") { showGoalEditor = true }
                            .foregroundStyle(StrandPalette.accent)
                        Button("Set aside") { showSetAsideDialog = true }
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .font(StrandFont.footnote)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// One honest line: how long is left, whether the pace was flagged — or how the goal ended.
    private var goalSubtitle: String {
        guard let goal = goalStore.goal else {
            return "A target and a date let the coach tell you where you stand. Optional."
        }
        switch goal.status {
        case .achieved:  return "Achieved — nicely done."
        case .abandoned: return "Set aside. A new goal is one tap away."
        case .active, .paused, .archived: break
        }
        var parts: [String] = []
        if let weeks = goal.weeksRemaining() {
            parts.append(weeks < 0 ? "target date passed"
                                   : String(format: "%.0f weeks to go", weeks.rounded()))
        }
        let gate = GoalSafetyGate.assess(goal: goal, bodyWeightKg: ProfileStore().weightKg)
        if gate.verdict == .aggressive || gate.verdict == .veryAggressive {
            parts.append(goal.acknowledgedRisk != nil ? "brisk pace, acknowledged" : "brisk pace")
        }
        return parts.isEmpty ? "No target date set" : parts.joined(separator: " · ")
    }

    // MARK: - Memory

    private var memoryBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: memoryExpanded ? 10 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) { memoryExpanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "brain")
                            .foregroundStyle(memory.facts.isEmpty
                                             ? StrandPalette.textTertiary : StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Coach memory")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(memory.facts.isEmpty
                                 ? "What the coach remembers about you, across conversations."
                                 : "\(memory.facts.count) remembered fact\(memory.facts.count == 1 ? "" : "s"). The coach uses these in every reply.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: memoryExpanded ? "chevron.up" : "chevron.down")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(memoryExpanded ? "Collapse coach memory" : "Show coach memory")

                if memoryExpanded {
                    if !memory.facts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Remembered").strandOverline()
                            ForEach(memory.facts) { fact in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: fact.category.symbol)
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .accessibilityHidden(true)
                                    if fact.importance == .pinned {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(StrandPalette.accent)
                                            .accessibilityLabel("Pinned")
                                    }
                                    Text(fact.text)
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Button {
                                        editingFactText = fact.text
                                        editingFactID = fact.id
                                    } label: {
                                        Image(systemName: "pencil")
                                            .foregroundStyle(StrandPalette.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Edit: \(fact.text)")
                                    Button {
                                        memory.remove(fact.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(StrandPalette.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Forget: \(fact.text)")
                                }
                            }
                            HStack {
                                Spacer()
                                Button {
                                    memory.clearAll()
                                } label: {
                                    Label("Forget everything", systemImage: "trash")
                                        .font(StrandFont.footnote)
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityLabel("Forget all remembered facts")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - System prompt

    private var systemPromptBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: promptExpanded ? 10 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) {
                        promptExpanded.toggle()
                        if promptExpanded { promptDraft = coach.customSystemPrompt }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "text.alignleft")
                            .foregroundStyle(coach.hasCustomSystemPrompt ? StrandPalette.accent : StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Coach instructions")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(coach.hasCustomSystemPrompt
                                 ? "Customised. Your edited instructions frame every reply."
                                 : "Edit how the coach thinks and talks. Takes effect on your next message.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: promptExpanded ? "chevron.up" : "chevron.down")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(promptExpanded ? "Collapse coach instructions" : "Edit coach instructions")

                if promptExpanded {
                    TextEditor(text: $promptDraft)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140, maxHeight: 240)
                        .padding(8)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onChangeCompat(of: promptDraft) { newValue in
                            coach.customSystemPrompt = newValue
                        }
                        .accessibilityLabel("Coach instructions editor")

                    HStack {
                        Spacer()
                        Button {
                            coach.resetSystemPrompt()
                            promptDraft = coach.customSystemPrompt
                        } label: {
                            Label("Reset to default", systemImage: "arrow.uturn.backward")
                                .font(StrandFont.footnote)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                        .disabled(!coach.hasCustomSystemPrompt)
                        .accessibilityLabel("Reset coach instructions to default")
                    }
                }
            }
        }
    }

    // MARK: - Setup (no key yet)

    private var setupCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Connect a provider")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                Text("Coach uses your own API key. Pick a provider, paste a key, and choose a model. Your key is stored securely in the Keychain and never leaves \(Platform.deviceNounPhrase) except as the request you make.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                providerConfigFields
            }
        }
    }

    /// Provider / server-URL / model / key controls. Shared by `setupCard` (not yet connected) and the
    /// "Connection & model" hub subpage (once connected) — before the hub, once `isConfigured` was true
    /// the only path back to these controls was `disconnectRow`, i.e. disconnecting first. Same fields,
    /// same actions, just reachable from a second place now.
    @ViewBuilder
    private var providerConfigFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Provider").strandOverline()
            // .menu, not .segmented: "Custom (OpenAI-compatible)" alongside three other labels doesn't
            // fit a 4-way segmented control on iPhone width without truncating. Same style CoachGoalView
            // already uses for its own multi-option picker.
            Picker("Provider", selection: $coach.provider) {
                ForEach(AIProvider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.menu)
            .tint(StrandPalette.accent)
            .accessibilityLabel("Provider")
        }

        if coach.provider == .custom {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL").strandOverline()
                TextField("http://localhost:11434/v1", text: $coach.customBaseURL)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .disableAutocorrection(true)
                    .accessibilityLabel("Server URL")
                Text("Any OpenAI-compatible server: Ollama, LM Studio, llama.cpp, or your own gateway. Stays on your network; nothing leaves \(Platform.deviceNounPhrase).")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        modelSelector

        VStack(alignment: .leading, spacing: 6) {
            Text(coach.provider == .custom ? "API key (optional)" : "API key").strandOverline()
            SecureField(coach.provider == .custom
                        ? "Only if your server requires one"
                        : "Paste your \(coach.provider.displayName) API key", text: $keyDraft)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                .onSubmit { coach.provider == .custom ? connectCustom() : saveKey() }
                .accessibilityLabel("API key")
            apiKeyHelpRow
        }

        HStack {
            if coach.provider == .custom {
                NoopButton("Connect", systemImage: "link", kind: .primary, action: connectCustom)
                    .disabled(coach.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                NoopButton("Save key", systemImage: "key.fill", kind: .primary, action: saveKey)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
        }
    }

    /// A first-time, non-technical user hits a wall at "paste your API key" with no idea where one comes
    /// from. One static link to the provider's own key page — no telemetry, no in-app browser, just
    /// `Link` opening the system browser. Nothing to show for Custom: a self-hosted server has no key
    /// vendor of its own.
    @ViewBuilder
    private var apiKeyHelpRow: some View {
        if let url = apiKeyHelpURL {
            Link(destination: url) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .accessibilityHidden(true)
                    Text("Don't have a key? Get one from \(coach.provider.displayName).")
                        .font(StrandFont.footnote)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(StrandPalette.accent)
            }
        }
    }

    private var apiKeyHelpURL: URL? {
        switch coach.provider {
        case .openAI:     return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic:  return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini:     return URL(string: "https://aistudio.google.com/apikey")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .custom:     return nil
        }
    }

    /// Above this many entries an inline `.menu` Picker stops being usable — today only OpenRouter's
    /// 300+ catalogue crosses it, but the switch below is a plain count check, not a provider name, so
    /// any provider whose live list grows past this threshold gets the searchable sheet automatically.
    private static let searchableModelThreshold = 50

    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model").strandOverline()
                Spacer()
                Button {
                    Task { await coach.refreshModels() }
                } label: {
                    Label("Refresh models", systemImage: "arrow.clockwise")
                        .font(StrandFont.footnote)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                // Custom is deliberately keyless for local servers (Ollama, LM Studio) — a base URL is
                // enough to list models there.
                .disabled(!coach.hasKey && coach.provider != .custom)
                .help("Fetch the available models from \(coach.provider.displayName) using your saved key")
                .accessibilityLabel("Refresh models from provider")
            }

            if coach.availableModels.count > Self.searchableModelThreshold {
                searchableModelButton
            } else {
                Picker("Model", selection: modelPickerSelection) {
                    ForEach(coach.availableModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                    Divider()
                    Text("Custom…").tag(customModelTag)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Model")

                if isCustomModelSelected {
                    HStack(spacing: 8) {
                        TextField("Enter a model id", text: $customModelDraft)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .onSubmit(applyCustomModel)
                            .accessibilityLabel("Custom model id")

                        Button("Use", action: applyCustomModel)
                            .buttonStyle(NoopButtonStyle(.secondary))
                            .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Use custom model")
                    }
                }
            }
        }
        .sheet(isPresented: $showModelSearch) {
            ModelSearchSheet(models: coach.availableModels, selection: $coach.model)
        }
    }

    /// Opens the searchable sheet. Free-text entry lives IN the sheet (typing an unmatched query offers
    /// it directly), so this path skips the inline picker's separate "Custom…" tag/TextField dance —
    /// one way to type an id, not two.
    private var searchableModelButton: some View {
        Button { showModelSearch = true } label: {
            HStack {
                Text(coach.model.isEmpty ? "Choose a model" : coach.model)
                    .font(StrandFont.body)
                    .foregroundStyle(coach.model.isEmpty ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(coach.model.isEmpty
                            ? "Model not set. Opens a searchable list of \(coach.availableModels.count) models."
                            : "Model: \(coach.model). Opens a searchable list of \(coach.availableModels.count) models.")
    }

    /// Whether the model field should read as "Custom…" — either the user explicitly picked that tag,
    /// or `coach.model` isn't (yet) one of `availableModels`. The latter covers the moment right after
    /// switching to a provider whose model list starts empty (Custom, and briefly any provider before
    /// `refreshModels()` returns): the engine resets `model` to `""` and `availableModels` to `[]`
    /// together, so this always agrees with what the Picker can actually show — no tag ever goes
    /// unmatched, and the free-text field appears without the user first having to find "Custom…" in a
    /// menu that had nothing else to show.
    private var isCustomModelSelected: Bool {
        customModel || !coach.availableModels.contains(coach.model)
    }

    private var modelPickerSelection: Binding<String> {
        Binding(
            get: { isCustomModelSelected ? customModelTag : coach.model },
            set: { newValue in
                if newValue == customModelTag {
                    customModel = true
                    if customModelDraft.isEmpty { customModelDraft = coach.model }
                } else {
                    customModel = false
                    coach.model = newValue
                }
            }
        )
    }

    private var privacyFootnote: some View {
        Label {
            Text(coach.provider == .custom
                 ? "Coach talks only to the server URL you set. Point it at a local model (Ollama, LM Studio, llama.cpp) to keep everything on your own machine. Nothing is sent until you ask."
                 : "This is the only feature that leaves \(Platform.deviceNounPhrase). It sends a summary of your metrics to \(coach.provider.displayName) using your own key. Nothing is sent until you ask.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func applyCustomModel() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setCustomModel(trimmed)
        customModel = false
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setKey(trimmed)
        keyDraft = ""
    }

    private func connectCustom() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            coach.setKey(trimmed)
            keyDraft = ""
        }
        coach.connectCustom()
    }
}
