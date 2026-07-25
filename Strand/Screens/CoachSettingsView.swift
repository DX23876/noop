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

    /// Apple Health-style leading-icon coloring (SettingsView's "App icon colors") — same switch that
    /// recolors the More tab and the rest of Coach's screens. See `CoachIconColors`.
    @AppStorage("noop.moreRowAppleHealthColors") private var appleHealthColors = true

    /// Pending key text (never persisted here, handed to `setKey`).
    @State private var keyDraft: String = ""
    /// Whether `keyDraft` renders as plaintext (show/hide toggle, #P4 5.1) — while TYPING a new key
    /// only; the already-stored key is never loaded back into this field to be revealed.
    @State private var keyDraftVisible: Bool = false
    /// Confirmation gate before `clearKey()` — a deliberately separate, harder-to-reach action from
    /// Disconnect (#P4 4.3), since it actually deletes the Keychain key.
    @State private var showForgetKeyConfirm = false
    /// Presents the "How Coach works" transparency page (#P6 6.2).
    @State private var showCoachInfo = false
    @State private var customModel: Bool = false
    @State private var customModelDraft: String = ""
    @State private var promptExpanded: Bool = false
    @State private var promptDraft: String = ""
    /// Which model field's searchable sheet is open — the coaching model, or one of the two background
    /// roles (#R5). One enum-driven `.sheet(item:)` (same consolidation as R2's goal sheets) rather than
    /// three independently-toggled `.sheet(isPresented:)` modifiers, since all three fields live in the
    /// same Connection & model subpage. Only reachable once a provider's list exceeds
    /// `searchableModelThreshold` (today just OpenRouter).
    private enum ModelSearchTarget: Int, Identifiable {
        case chat, summary, cardAnalysis, deepAnalysis
        var id: Int { rawValue }
    }
    @State private var modelSearchTarget: ModelSearchTarget?
    /// Custom-id entry state for the two background-role pickers, mirroring `customModel`/
    /// `customModelDraft` above (#R5) — each role needs its own, since either can independently be
    /// mid-way through typing a model id the current provider's list doesn't have (yet).
    @State private var memoryModelCustom: Bool = false
    @State private var memoryModelCustomDraft: String = ""
    @State private var cardModelCustom: Bool = false
    @State private var cardModelCustomDraft: String = ""
    @State private var deepModelCustom: Bool = false
    @State private var deepModelCustomDraft: String = ""
    @State private var checkInOn: Bool = CoachCheckIn.isEnabled
    @State private var checkInTime: Date = CoachCheckIn.timeAsDate
    @State private var checkInMode: CoachCheckIn.Mode = CoachCheckIn.mode
    /// The learned habitual wake minute mirrored into view state, so the `.afterWake` readout updates
    /// after the async refresh writes it (reading UserDefaults directly wouldn't re-render).
    @State private var checkInResolvedWake: Int? = CoachCheckIn.resolvedWakeMinutes
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

    /// Any active goal whose date has passed (#R-multi-goal: there can be several now) — the same
    /// condition `expiredGoalCard` acts on — is exactly the state B2 gave a decision UI to; the badge is
    /// what tells you one is waiting.
    private var goalNeedsAttention: Bool {
        goalStore.activeGoals.contains { $0.status == .active && (ProactiveCoach.daysPastTarget($0) ?? 0) >= 1 }
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
    /// The coach's identity (#R9) — name, avatar, tone. Observed so the `identityBar` row updates live.
    @ObservedObject private var identityStore = CoachIdentityStore.shared
    /// The structured goal (P3). The memory card's field still edits its title inline; the full editor
    /// with target/date/pace lives in the dedicated goal card.
    @ObservedObject private var goalStore = CoachGoalStore.shared
    @ObservedObject private var usage = CoachUsageLog.shared
    @State private var memoryExpanded: Bool = false
    /// How the user reaches Coach from Today: the card, the draggable floating button, or both.
    @AppStorage(CoachEntryMode.storageKey) private var coachEntryModeRaw = CoachEntryMode.both.rawValue
    /// Master switch for the Coach's home-surface UI (#R7). Off hides the Today header avatar and floating
    /// button; card- and background-AI, and the coach settings themselves, are untouched.
    @AppStorage(CoachEntryMode.uiEnabledKey) private var coachUIEnabled = true
    /// Show the coach's avatar on the Today entry (#R11); off restores the plain sparkle icon.
    @AppStorage(CoachEntryMode.todayAvatarKey) private var todayAvatar = true
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
    /// What the last "Summarise this chat now" tap actually did. Repeat taps on an already-processed
    /// chat are a no-op by design (they'd otherwise re-distil the same facts into duplicate memory
    /// entries), and a button that silently does nothing reads as a broken button — so it says so.
    @State private var summarizeOutcome: AICoachEngine.SummarizeOutcome?

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
                                .foregroundStyle(appleHealthColors
                                                 ? CoachIconColors.color(for: "coach.settings.connection")
                                                 : StrandPalette.accent)
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
                                .foregroundStyle(appleHealthColors
                                                 ? CoachIconColors.color(for: "coach.settings.goalJourney")
                                                 : StrandPalette.accent)
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
                                .foregroundStyle(appleHealthColors
                                                 ? CoachIconColors.color(for: "coach.settings.coaching")
                                                 : StrandPalette.accent)
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
                                .foregroundStyle(appleHealthColors
                                                 ? CoachIconColors.color(for: "coach.settings.memory")
                                                 : StrandPalette.accent)
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
                                .foregroundStyle(appleHealthColors
                                                 ? CoachIconColors.color(for: "coach.settings.privacy")
                                                 : StrandPalette.accent)
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
            connectionTestRow
            backgroundModelsSection
            tokenUsageBar
            cumulativeUsageBar
            openRouterBalanceBar
            disconnectRow
        }
        .navigationTitle("Connection & model")
        .sheet(item: $modelSearchTarget) { target in
            switch target {
            case .chat:         ModelSearchSheet(models: coach.availableModels, selection: $coach.model)
            case .summary:      ModelSearchSheet(models: coach.availableModels, selection: $coach.memoryModel)
            case .cardAnalysis: ModelSearchSheet(models: coach.availableModels, selection: $coach.cardModel)
            case .deepAnalysis: ModelSearchSheet(models: coach.availableModels, selection: $coach.deepModel)
            }
        }
    }

    /// The cheaper models the coach uses for BACKGROUND work, gathered in one place next to the coaching
    /// model (#P5 5.2–5.4 / 6.1): a `.summary` model (distilling finished chats into memory) and a
    /// `.cardAnalysis` model (a short read of one health card). Both default to the provider's cheap
    /// model when left blank, so a user who ignores this pays nothing extra and nothing breaks — the
    /// placeholder shows exactly which model that fallback resolves to.
    @ViewBuilder
    private var backgroundModelsSection: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background models")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("Cheaper models for background jobs — leave on default to use \(coach.provider.displayName)'s small model. Keeps the pricey coaching model for the actual conversation.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    // Both roles read the SAME per-provider list `modelSelector`'s own Refresh button
                    // already updates (#R5) — repeated here too since this card is a separate visual
                    // section a user might reach without scrolling back up to it.
                    Button {
                        Task { await coach.refreshModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(StrandFont.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .disabled(!coach.hasKey && coach.provider != .custom)
                    .help("Fetch the available models from \(coach.provider.displayName) using your saved key")
                    .accessibilityLabel("Refresh models from provider")
                }
                roleModelField(
                    title: "Chat summaries",
                    caption: "Distils a finished chat so the coach can recall it later.",
                    model: $coach.memoryModel, custom: $memoryModelCustom, customDraft: $memoryModelCustomDraft,
                    searchTarget: .summary,
                    accessibility: "Chat-summary model"
                )
                roleModelField(
                    title: "Card analyses",
                    caption: "A short read when you ask the coach about one health card.",
                    model: $coach.cardModel, custom: $cardModelCustom, customDraft: $cardModelCustomDraft,
                    searchTarget: .cardAnalysis,
                    accessibility: "Card-analysis model"
                )
                roleModelField(
                    title: "Closer look",
                    caption: "An optional heavier model for \"Look at this more closely\" on a reply. Leave unset to hide that option.",
                    model: $coach.deepModel, custom: $deepModelCustom, customDraft: $deepModelCustomDraft,
                    searchTarget: .deepAnalysis,
                    accessibility: "Closer-look model",
                    emptyLabel: "Off — no closer-look option"
                )
            }
        }
    }

    /// The spoken version of the proactive-level setting.
    ///
    /// Built from LOCALIZED pieces on purpose. `ProactiveLevel.label` / `.blurb` are English constants
    /// that the visible UI runs through `LocalizedStringKey`; interpolating them straight into an
    /// accessibility string — as this did — produced a label VoiceOver read in English no matter the
    /// device language. An accessibility affordance that only works for English readers is worse than
    /// none, because it looks handled.
    private static func proactiveLevelReadout(_ level: ProactiveLevel) -> String {
        let name = String(localized: String.LocalizationValue(level.label))
        let blurb = String(localized: String.LocalizationValue(level.blurb))
        return String(localized: "Currently: \(name). \(blurb)")
    }

    /// The spoken version of the verbosity setting — same localized-pieces reasoning as
    /// `proactiveLevelReadout` above.
    /// What to say after a "Summarise this chat now" tap. `alreadyUpToDate` is the important one: it is
    /// the correct, deliberate no-op that stops a repeat tap from re-distilling the same chat into
    /// duplicate memory facts, so it has to read as a result rather than as nothing happening.
    private static func summarizeOutcomeLine(_ outcome: AICoachEngine.SummarizeOutcome) -> String {
        switch outcome {
        case .started:
            return String(localized: "Summarising in the background — new facts appear above.")
        case .alreadyUpToDate:
            return String(localized: "Already summarised — nothing new in this chat since last time.")
        case .nothingToSummarize:
            return String(localized: "Nothing to summarise in this chat yet.")
        case .noConsent:
            return String(localized: "Turn on data sharing under Privacy & data to use this.")
        }
    }

    private static func verbosityReadout(_ verbosity: CoachVerbosity) -> String {
        let name = String(localized: String.LocalizationValue(verbosity.label))
        let blurb = String(localized: String.LocalizationValue(verbosity.blurb))
        return String(localized: "Currently: \(name). \(blurb)")
    }

    /// One model field for a background role (#R5) — the SAME picker/searchable-sheet/"Custom…" pattern
    /// `modelSelector` uses for the coaching model, not a bare `TextField`: every model the provider
    /// actually offers is selectable, not just typeable-and-hope. Empty ("") is its own real option,
    /// "Same as coaching model" — the role's default — kept distinct from "Custom…" (typing an id outside
    /// the fetched list).
    /// `emptyLabel` names what an unset field MEANS, which differs per role: for the background roles
    /// empty is "fall back to the coaching model", but for Closer look empty means the feature is off and
    /// its action stays hidden. Showing "Same as coaching model" there would promise a fallback that
    /// deliberately doesn't happen.
    private func roleModelField(title: LocalizedStringKey, caption: LocalizedStringKey,
                                model: Binding<String>, custom: Binding<Bool>, customDraft: Binding<String>,
                                searchTarget: ModelSearchTarget, accessibility: String,
                                emptyLabel: LocalizedStringKey = "Same as coaching model") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).strandOverline()

            if coach.availableModels.count > Self.searchableModelThreshold {
                Button { modelSearchTarget = searchTarget } label: {
                    HStack {
                        Text(model.wrappedValue.isEmpty ? emptyLabel : LocalizedStringKey(model.wrappedValue))
                            .font(StrandFont.body)
                            .foregroundStyle(model.wrappedValue.isEmpty
                                             ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibility)
            } else {
                Picker(title, selection: roleModelPickerSelection(model: model, custom: custom, draft: customDraft)) {
                    Text(emptyLabel).tag("")
                    ForEach(coach.availableModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                    Divider()
                    Text("Custom…").tag(customModelTag)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(accessibility)

                if custom.wrappedValue {
                    HStack(spacing: 8) {
                        TextField("Enter a model id", text: customDraft)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .disableAutocorrection(true)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .onSubmit { applyCustomRoleModel(model: model, custom: custom, draft: customDraft) }
                            .accessibilityLabel("Custom model id")

                        Button("Use") { applyCustomRoleModel(model: model, custom: custom, draft: customDraft) }
                            .buttonStyle(NoopButtonStyle(.secondary))
                            .disabled(customDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Use custom model")
                    }
                }
            }
            Text(caption)
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Mirrors `modelPickerSelection` for a background role: reads as `customModelTag` when the field is
    /// mid-custom-entry OR holds a non-empty value the current provider's list doesn't have (e.g. right
    /// after a provider switch invalidates it) — so the Picker never shows an unmatched tag, and empty
    /// always reads as the real "Same as coaching model" option rather than falling into Custom.
    private func roleModelPickerSelection(model: Binding<String>, custom: Binding<Bool>,
                                          draft: Binding<String>) -> Binding<String> {
        Binding(
            get: {
                if custom.wrappedValue { return customModelTag }
                if model.wrappedValue.isEmpty { return "" }
                return coach.availableModels.contains(model.wrappedValue) ? model.wrappedValue : customModelTag
            },
            set: { newValue in
                if newValue == customModelTag {
                    custom.wrappedValue = true
                    if draft.wrappedValue.isEmpty { draft.wrappedValue = model.wrappedValue }
                } else {
                    custom.wrappedValue = false
                    model.wrappedValue = newValue
                }
            }
        )
    }

    private func applyCustomRoleModel(model: Binding<String>, custom: Binding<Bool>, draft: Binding<String>) {
        let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.wrappedValue = trimmed
        custom.wrappedValue = false
    }

    /// The goal + journey content now lives in the standalone `CoachGoalJourneyView` (#R6) — which owns
    /// the ONE enum-driven sheet + ONE enum-driven confirmation dialog the goal card needs (the R2 fix,
    /// carried over) — so the same surface is reachable both here (settings hub) and as a top-level menu
    /// entry. This subpage just hosts it in the shared scaffold.
    private var goalJourneySubpage: some View {
        subpageScaffold {
            CoachGoalJourneyView()
        }
        .navigationTitle("Goal & Journey")
    }

    private var coachingSubpage: some View {
        subpageScaffold {
            coachVisibilityBar
            presetBar
            identityBar
            personaBar
            emojiBar
            verbosityBar
            coachEntryBar
            morningSuggestionBar
            proactiveBar
            checkInBar
            planReminderBar
        }
        .navigationTitle("Coaching")
        .task { await refreshCheckInAuthorization() }
    }

    /// One-tap bundles over persona + voice + emoji + proactive level + reply length (`CoachPreset`) — a
    /// faster starting point than setting each of those five controls individually. Applying one only
    /// writes into the stores those controls already read from, so every row below still shows the result
    /// and stays individually editable afterward.
    private var presetBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(appleHealthColors
                                        ? CoachIconColors.color(for: "coach.settings.presets") : StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Quick presets")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("Sets persona, voice, emoji, proactive messages, and reply length together — tweak any of them below afterward.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(CoachPreset.allCases) { preset in
                    Button {
                        preset.apply(to: coach, identity: identityStore)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: preset.symbol)
                                .foregroundStyle(appleHealthColors
                                                ? CoachIconColors.color(for: "coach.preset.\(preset.rawValue)")
                                                : StrandPalette.accent)
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(LocalizedStringKey(preset.title))
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text(LocalizedStringKey(preset.subtitle))
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Apply preset: \(preset.title)")
                    .accessibilityHint(preset.subtitle)
                }
            }
        }
    }

    /// Entry into the coach-identity editor (#R9): the coach's name + picture + tone (the "who"), distinct
    /// from the coaching STYLE (`personaBar`, the "how"). A compact row showing the current avatar + name,
    /// pushing the full editor.
    private var identityBar: some View {
        NavigationLink { CoachIdentityEditor() } label: {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                HStack(spacing: 10) {
                    CoachAvatarView(size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Coach identity")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(identityStore.identity.name)
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coach identity: \(identityStore.identity.name)")
    }

    /// Emoji in coach replies (#P14 7.3) — off by default (matches the careful voice from P13); a plain
    /// opt-in toggle, same shape as the other binary settings on this page.
    private var emojiBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.allowEmoji ? "face.smiling.fill" : "face.smiling")
                    .foregroundStyle(coach.allowEmoji ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Emoji in replies")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.allowEmoji
                         ? "On: the coach may use the odd, well-placed emoji."
                         : "Off: replies are plain text only.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.allowEmoji)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Emoji in replies")
            }
        }
    }

    /// Reply length — concise / normal / detailed. Same segmented-picker shape as `proactiveBar`; `normal`
    /// leaves today's replies unchanged, the other two steer via a prompt clause (`CoachVerbosity`).
    private var verbosityBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(appleHealthColors
                                        ? CoachIconColors.color(for: "coach.settings.verbosity") : StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reply length")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(LocalizedStringKey(coach.verbosity.blurb))
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                Picker("Reply length", selection: $coach.verbosity) {
                    ForEach(CoachVerbosity.allCases) { level in Text(LocalizedStringKey(level.label)).tag(level) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("How long the coach's replies run")
                Text(LocalizedStringKey(coach.verbosity.blurb))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Self.verbosityReadout(coach.verbosity))
            }
        }
    }

    /// How chatty the coach is UNPROMPTED (#P10 10.4) — proactive messages cost tokens, so this is a
    /// user dial: off / only important / normal.
    private var proactiveBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(coach.proactiveLevel == .off ? StrandPalette.textTertiary
                            : (appleHealthColors ? CoachIconColors.color(for: "coach.settings.proactive")
                                                  : StrandPalette.accent))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Proactive messages")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(LocalizedStringKey(coach.proactiveLevel.blurb))
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                Picker("Proactive messages", selection: $coach.proactiveLevel) {
                    ForEach(ProactiveLevel.allCases) { level in Text(LocalizedStringKey(level.label)).tag(level) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("How often the coach messages you first")
                // A segmented picker marks its selection with a highlight and nothing else, so which
                // option is active is carried by colour alone. Restating it in words costs one line and
                // makes the current setting readable without seeing that highlight at all.
                Text(LocalizedStringKey(coach.proactiveLevel.blurb))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Self.proactiveLevelReadout(coach.proactiveLevel))
                Text("The coach only reaches out on a real milestone or a run of missed sessions — never chatter. Each message uses your provider (and your tokens).")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
            howItWorksRow
            consentBar
            if coach.dataConsent { dataAccessRow }
            // Coach Instructions (the actual editable setting) before the explanatory note (#R4) — the
            // settings lead, the rationale follows.
            systemPromptBar
            dataTransparencyNote
        }
        .navigationTitle("Privacy & data")
    }

    /// Entry into `dataAccessSubpage` — per-purpose tool consent (#coach-tool-consent), one level under
    /// the master `dataConsent` switch, so it only shows once there's something to narrow.
    private var dataAccessRow: some View {
        NavigationLink { dataAccessSubpage } label: {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                HStack(spacing: 10) {
                    Image(systemName: "switch.2")
                        .foregroundStyle(appleHealthColors
                                        ? CoachIconColors.color(for: "coach.settings.dataAccess") : StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Data access")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("Choose what the coach can fetch, log and remember.")
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
    }

    /// Per-purpose tool consent (#coach-tool-consent): seven groups narrowing what `dataConsent` already
    /// allows overall. `onDeviceSignalsBar` (the pre-existing second opt-in) folds in here as the
    /// `.patterns` row rather than being duplicated — it already reads/writes the same underlying
    /// `toolConsent` via `coach.includeOnDeviceSignals`.
    private var dataAccessSubpage: some View {
        subpageScaffold {
            coreBiometricsAccessBar
            workoutsAccessBar
            planningAccessBar
            stressAccessBar
            logsAccessBar
            memoryToolsAccessBar
            onDeviceSignalsBar
        }
        .navigationTitle("Data access")
    }

    /// A `Binding` onto one `CoachPurpose`'s membership in `toolConsent.enabled` — thin projection, no
    /// new state; the persisted source of truth stays `coach.toolConsent`.
    private func purposeBinding(_ purpose: CoachPurpose) -> Binding<Bool> {
        Binding(
            get: { coach.toolConsent.enabled.contains(purpose) },
            set: { on in
                if on { coach.toolConsent.enabled.insert(purpose) } else { coach.toolConsent.enabled.remove(purpose) }
            }
        )
    }

    private var coreBiometricsAccessBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: "heart.text.square")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.coreBiometrics)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Core biometrics")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Charge, sleep detail, readiness and charge drivers.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.coreBiometrics))
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Let the coach fetch core biometrics")
            }
        }
    }

    private var workoutsAccessBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: "figure.run")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.workouts)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Workouts")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Recent workouts, zone minutes and session outlook.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.workouts))
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Let the coach fetch workouts")
            }
        }
    }

    private var planningAccessBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.toolConsent.enabled.contains(.planning)
                     ? "calendar.badge.clock" : "calendar")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.planning)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Planning")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Suggesting sessions and checking what you actually did.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.planning))
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Let the coach suggest and review sessions")
            }
        }
    }

    private var stressAccessBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.heart")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.stress)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stress")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Today's derived stress index.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.stress))
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Let the coach fetch the stress index")
            }
        }
    }

    private var logsAccessBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.clipboard")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.logs)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Logging")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Reading and logging caffeine, journal entries and Lab Book markers.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.logs))
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Let the coach read and log your entries")
            }
        }
    }

    private var memoryToolsAccessBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.memory)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memory tools")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Saving, correcting and forgetting facts, and searching past chats.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.memory))
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Let the coach save and search memory")
            }
        }
    }

    /// Entry into the full how-the-coach-works / what's-shared page (#P6 6.2). A row, not buried text,
    /// so the transparency story is one tap from where consent is granted.
    private var howItWorksRow: some View {
        Button { showCoachInfo = true } label: {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(appleHealthColors
                                        ? CoachIconColors.color(for: "coach.settings.howItWorks") : StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("How Coach works")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("What runs on \(Platform.deviceNounPhrase), what's sent, and why the model matters.")
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
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .sheet(isPresented: $showCoachInfo) { CoachInfoView().environmentObject(coach) }
    }

    /// The data-sharing posture in plain words (#P6 6.4 / 14.x): the coach is DELIBERATELY data-driven —
    /// that's its value — so the honest goal is transparency and picking a trustworthy provider, not
    /// starving it of data. Names the provider so the privacy question is concrete.
    private var dataTransparencyNote: some View {
        Label {
            Text(coach.provider == .custom
                 ? "The coach works with your data on purpose — that's what makes it personal. With a Custom server you point it at, nothing leaves \(Platform.deviceNounPhrase) at all. NOOP only ever sends what a request needs — a summary of the relevant metrics, never raw sensor data."
                 : "The coach works with your data on purpose — that's what makes it personal. The real privacy question is your provider (\(coach.provider.displayName)): they receive what you send, so choose one you trust. NOOP only ever sends what a request needs — a summary of the relevant metrics, never raw sensor data or unrelated personal details.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Coach UI master switch (#R7) — hides the home-surface entry points, keeps card/background AI

    private var coachVisibilityBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $coachUIEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show Coach on Today")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("Turn off to hide the Coach card and floating button. Per-metric “Ask coach” and the AI that writes your card summaries keep working.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(StrandPalette.accent)

                if coachUIEnabled {
                    Divider().overlay(StrandPalette.hairline)
                    Toggle(isOn: $todayAvatar) {
                        HStack(spacing: 10) {
                            CoachAvatarView(size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Show coach avatar")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("Use your coach’s picture on the Today entry instead of a plain icon.")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .tint(StrandPalette.accent)
                }
            }
        }
    }

    // MARK: - Coach entry preference (iOS: card vs. draggable floating button vs. both)

    @ViewBuilder private var coachEntryBar: some View {
        #if os(iOS)
        if coachUIEnabled {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap")
                        .foregroundStyle(appleHealthColors
                                        ? CoachIconColors.color(for: "coach.settings.entry") : StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Coach entry")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("How you open Coach from Today — a list row, a draggable floating button, or both.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                Picker("Coach entry", selection: $coachEntryModeRaw) {
                    ForEach(CoachEntryMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.label)).tag(mode.rawValue)
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
        }
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    /// Pin the floating button to one of four chrome-clear corners, or lock it where it is. Four tappable
    /// icons rather than a Picker: a segmented Picker can't show a no-corner-selected state for a dragged button.
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
                    .accessibilityLabel(Text(LocalizedStringKey(c.label)))
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                }
            }
            // Both branches resolved via String(localized:) rather than left as a literal ternary (#P14):
            // the pinned branch embeds `corner.label`, a fixed-set English computed property, and a plain
            // Text(String) never performs a catalog lookup — so without pre-resolving it here, the label
            // itself would ride along in English even once the surrounding sentence translates.
            Text(corner == .custom
                 ? String(localized: "Dragged freely — tap a corner to pin it. Corners stay clear of the tab bar and header.")
                 : String(localized: "Pinned: \(corner.label.localizedCatalogValue). Drag the button anytime to place it freely."))
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
                        .foregroundStyle(!coach.autoSummarize ? StrandPalette.textTertiary
                            : (appleHealthColors ? CoachIconColors.color(for: "coach.settings.autoSummarize")
                                                  : StrandPalette.accent))
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

                Text("The model this uses lives under Connection & model → Background models.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button {
                        summarizeOutcome = coach.activeConversationID.map { coach.summarizeNow($0) }
                                        ?? .nothingToSummarize
                    } label: {
                        Label("Summarise this chat now", systemImage: "sparkles")
                            .font(StrandFont.footnote).labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityLabel("Summarise the current chat now")
                }

                if let outcome = summarizeOutcome {
                    Text(Self.summarizeOutcomeLine(outcome))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel(Self.summarizeOutcomeLine(outcome))
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
                // `+` string concatenation types the whole thing as plain `String`, which
                // `.accessibilityLabel(String)` never runs through the catalog — String(localized:)
                // interpolation is what actually localizes the static wrapper text around the two
                // dynamic, already-computed pieces.
                .accessibilityLabel(String(localized: "Last question token usage. \(CoachUsageLog.summaryLine(for: turn)). \(CoachUsageLog.cacheVerdict(for: turn))"))
            }
        }
    }

    /// Cumulative token counters — today (rolls at 04:00, persisted) and this app session (resets on
    /// relaunch). Same on-device counting as `tokenUsageBar`, just totalled instead of last-question-only,
    /// so the one choice OpenRouter users actually make (which model) has a running answer instead of only
    /// a single-question snapshot. Hidden until at least one question has been counted, same as above.
    @ViewBuilder
    private var cumulativeUsageBar: some View {
        if usage.dayQuestionCount > 0 {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.bar.fill")
                            .foregroundStyle(appleHealthColors
                                            ? CoachIconColors.color(for: "coach.settings.usage") : StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Usage so far")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 8)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text(CoachUsageLog.cumulativeSummaryLine(for: usage.dayTotal, questionCount: usage.dayQuestionCount))
                            .font(StrandFont.footnote.monospacedDigit())
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This session")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text(CoachUsageLog.cumulativeSummaryLine(for: usage.sessionTotal, questionCount: usage.sessionQuestionCount))
                            .font(StrandFont.footnote.monospacedDigit())
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text("Counted on-device from what your provider reports back — not every request format reports usage, so this may undercount rather than overcount.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// OpenRouter's OWN account balance for this key — the one provider among the five whose usage/cost
    /// API works with a normal chat key (the others need an admin-scoped key this app never asks for; see
    /// `OpenRouterClient.fetchKeyInfo`). A manual pull, not an auto-refresh, so opening this screen never
    /// spends an extra request on its own.
    @ViewBuilder
    private var openRouterBalanceBar: some View {
        if coach.provider == .openRouter && coach.hasKey {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await coach.checkOpenRouterBalance() }
                    } label: {
                        Label("Check OpenRouter balance", systemImage: "creditcard")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(coach.openRouterBalance == .checking)
                    .accessibilityHint("Asks OpenRouter directly for this key's own spend and limit.")

                    switch coach.openRouterBalance {
                    case .untested:
                        EmptyView()
                    case .checking:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking…").font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    case .ok(let info):
                        VStack(alignment: .leading, spacing: 2) {
                            if let limit = info.limitUSD {
                                Text(String(format: "$%.2f of $%.2f used", info.usageUSD, limit))
                                    .font(StrandFont.footnote.monospacedDigit())
                                    .foregroundStyle(StrandPalette.textSecondary)
                            } else {
                                Text(String(format: "$%.2f used — no limit set on this key", info.usageUSD))
                                    .font(StrandFont.footnote.monospacedDigit())
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            Text("Lifetime for this key, straight from OpenRouter — not a weekly or monthly figure.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusCritical)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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

    /// "Did that actually work?", answered here rather than by the user's first real question.
    ///
    /// A wrong key, a typo'd Custom URL or a model this account can't serve was previously only
    /// discovered by asking the coach something and getting an error back — after leaving settings. The
    /// test sends one minimal real request through the ordinary chat path, so it exercises exactly what
    /// a question would.
    @ViewBuilder
    private var connectionTestRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await coach.testConnection() }
            } label: {
                Label("Test connection", systemImage: "bolt.horizontal.circle")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(coach.connectionTest == .testing)
            .accessibilityHint("Sends one small request to check the key and model actually work.")

            switch coach.connectionTest {
            case .untested:
                EmptyView()
            case .testing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            case .ok(let model):
                Label("Works — \(model) replied.", systemImage: "checkmark.circle.fill")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusPositive)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var disconnectRow: some View {
        VStack(alignment: .trailing, spacing: 10) {
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
                .accessibilityHint("Stops using this provider. Your saved key is kept.")
            }
            // Deliberately a SEPARATE, smaller action from Disconnect (#P4 4.3): disconnecting stops
            // using the provider but keeps the key so reconnecting is one tap; forgetting the key is the
            // only thing that actually deletes it from the Keychain, and needs its own confirmation.
            if coach.provider != .custom && coach.hasKey {
                Button(role: .destructive) {
                    showForgetKeyConfirm = true
                } label: {
                    Text("Forget saved key")
                        .font(StrandFont.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHint("Deletes your \(coach.provider.displayName) key from the Keychain. You'll need to paste it again to reconnect.")
                .confirmationDialog(
                    "Forget your saved \(coach.provider.displayName) key?",
                    isPresented: $showForgetKeyConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Forget key", role: .destructive) {
                        coach.clearKey()
                        keyDraft = ""
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You'll need to paste it again to reconnect. This is different from Disconnect, which keeps the key.")
                }
            }
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
                        .foregroundStyle(appleHealthColors
                                        ? CoachIconColors.color(for: "coach.persona.\(coach.persona.rawValue)")
                                        : StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Coaching style")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(LocalizedStringKey(coach.persona.subtitle))
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
                        Text(LocalizedStringKey(p.title)).tag(p)
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
    /// no-key state.
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
                    Picker("When", selection: $checkInMode) {
                        Text("Fixed time").tag(CoachCheckIn.Mode.fixed)
                        Text("When I wake up").tag(CoachCheckIn.Mode.afterWake)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Check-in timing")
                    .onChangeCompat(of: checkInMode) { newValue in
                        CoachCheckIn.setMode(newValue)
                        // Learn the wake time now rather than waiting for the next foreground, so the
                        // readout below fills in immediately when there's enough sleep history.
                        if newValue == .afterWake {
                            Task {
                                await coach.refreshCoachCheckInSchedule()
                                checkInResolvedWake = CoachCheckIn.resolvedWakeMinutes
                            }
                        }
                    }

                    switch checkInMode {
                    case .fixed:
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
                    case .afterWake:
                        Text(checkInWakeReadout)
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
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

    /// The `.afterWake` explanation line: the learned wake time once there's enough sleep history, or a
    /// plain "still learning, using your fixed time meanwhile" while there isn't — so the mode never looks
    /// broken on a fresh install with no nights recorded yet.
    private var checkInWakeReadout: String {
        if let minutes = checkInResolvedWake {
            let clock = String(format: "%02d:%02d", minutes / 60, minutes % 60)
            return String(localized: "Tracks your wake time — around \(clock) lately. Refreshes each time you open NOOP.")
        }
        let fallback = String(format: "%02d:%02d", CoachCheckIn.timeMinutes / 60, CoachCheckIn.timeMinutes % 60)
        return String(localized: "Learning your wake time from your sleep. Until there's enough, it uses your fixed time (\(fallback)).")
    }

    /// Opt-in local reminder for a committed, timed plan session — a plan with a time is a plan you
    /// keep, made real. On-device only; no AI call fires it, and no notification exists until a session
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

    // MARK: - Memory

    private var memoryBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: memoryExpanded ? 10 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) { memoryExpanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "brain")
                            .foregroundStyle(memory.facts.isEmpty ? StrandPalette.textTertiary
                                : (appleHealthColors ? CoachIconColors.color(for: "coach.settings.memoryBar")
                                                      : StrandPalette.accent))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Coach memory")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(memory.facts.isEmpty
                                 ? String(localized: "What the coach remembers about you, across conversations.")
                                 : (memory.facts.count == 1
                                    ? String(localized: "1 remembered fact. The coach uses these in every reply.")
                                    : String(localized: "\(memory.facts.count) remembered facts. The coach uses these in every reply.")))
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
                    } else {
                        // Expanding onto nothing at all reads as a broken control (#coach-bugs): an empty
                        // memory is a normal state and has to SAY it's empty, and say how it fills.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memory is empty").strandOverline()
                            Text("The coach hasn't saved anything about you yet. It adds a fact when you tell it something durable — an injury, a constraint, how you like to train — and \"Summarise past chats\" below distils older conversations into facts too.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
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
                            .foregroundStyle(!coach.hasCustomSystemPrompt ? StrandPalette.textTertiary
                                : (appleHealthColors ? CoachIconColors.color(for: "coach.settings.systemPrompt")
                                                      : StrandPalette.accent))
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

    /// True when the user disconnected from the current (cloud) provider but its key is STILL in the
    /// Keychain (#P4 4.3: disconnect never deletes it) — the setup card then offers a one-tap Reconnect
    /// instead of asking them to paste the same key again.
    private var canReconnectWithoutKey: Bool {
        coach.provider != .custom && coach.hasKey && !coach.isConfigured
    }

    private var setupCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: canReconnectWithoutKey ? "key.fill" : "sparkles")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(canReconnectWithoutKey ? "Reconnect to \(coach.provider.displayName)" : "Connect a provider")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                if canReconnectWithoutKey {
                    Text("You disconnected, but your key is still saved locally — reconnect without re-entering it, or pick a different provider below.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NoopButton("Reconnect", systemImage: "link", kind: .primary) { coach.reconnect() }
                } else {
                    Text("Coach uses your own API key. Pick a provider, paste a key, and choose a model. Your key is stored securely in the Keychain and never leaves \(Platform.deviceNounPhrase) except as the request you make.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
            HStack(spacing: 8) {
                Text(coach.provider == .custom ? "API key (optional)" : "API key").strandOverline()
                // Distinguishes "empty" from "a key is saved, just not shown here" (#P4 5.1) — the
                // field itself always starts blank (the stored key is never loaded back into it).
                if coach.hasKey && keyDraft.isEmpty {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusPositive)
                }
            }
            HStack(spacing: 6) {
                Group {
                    if keyDraftVisible {
                        TextField(coach.provider == .custom
                                  ? "Only if your server requires one"
                                  : "Paste your \(coach.provider.displayName) API key", text: $keyDraft)
                            .disableAutocorrection(true)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    } else {
                        SecureField(coach.provider == .custom
                                    ? "Only if your server requires one"
                                    : "Paste your \(coach.provider.displayName) API key", text: $keyDraft)
                    }
                }
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .onSubmit { coach.provider == .custom ? connectCustom() : saveKey() }
                .accessibilityLabel("API key")

                // Show/hide toggle (#P4 5.1) — only ever reveals what's currently being TYPED; the
                // already-saved key is never re-loaded into this field, so there's nothing to leak.
                if !keyDraft.isEmpty {
                    Button {
                        keyDraftVisible.toggle()
                    } label: {
                        Image(systemName: keyDraftVisible ? "eye.slash" : "eye")
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(keyDraftVisible ? "Hide key" : "Show key")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
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

    /// A first-time, non-technical user hits a wall at paste-your-API-key with no idea where one comes
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
                Text("Coaching model").strandOverline()
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
    }

    /// Opens the searchable sheet. Free-text entry lives IN the sheet (typing an unmatched query offers
    /// it directly), so this path skips the inline picker's separate "Custom…" tag/TextField dance —
    /// one way to type an id, not two.
    private var searchableModelButton: some View {
        Button { modelSearchTarget = .chat } label: {
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
                 ? "Coach talks only to the server URL you set. Point it at a local model (Ollama, LM Studio, llama.cpp) to keep everything on your own machine. Data sharing is a separate, off-by-default choice you make after connecting, under Privacy & data."
                 : "This is the only feature that leaves \(Platform.deviceNounPhrase), and only once you turn it on. Sending a summary of your metrics to \(coach.provider.displayName) using your own key is a separate, off-by-default choice under Privacy & data, once you're connected.")
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
