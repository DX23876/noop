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

    /// The chat presents settings as a standalone sheet, so this view normally owns its NavigationStack.
    /// More already supplies a bound stack; nesting another one there makes SwiftUI update two navigation
    /// authorities in the same frame and leaves the More path unable to accept later pushes.
    private let usesHostNavigation: Bool

    init(usesHostNavigation: Bool = false) {
        self.usesHostNavigation = usesHostNavigation
    }

    /// Apple-inspired leading-icon coloring (SettingsView's "Apple-inspired colors") — same switch that
    /// recolors the More tab and the rest of Coach's screens. See `CoachIconColors`.
    @AppStorage(AppleInspiredColorsPrefs.enabledKey) private var appleHealthColors = AppleInspiredColorsPrefs.defaultEnabled

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
    /// Fine-grained purpose toggles are intentionally secondary to the three simple privacy modes.
    @State private var dataAccessExpertMode = false
    /// The Coach is an explicit opt-in feature. It starts off on a new installation, including when no
    /// provider/key has been configured yet; the settings remain reachable so setup is never a dead end.
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false

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

    /// A fact the coach saved but can't rely on until the user says it's right. An injury, goal or
    /// physiology fact is stored unconfirmed and is barred from the block that frames every reply, so
    /// one sitting here unanswered is a memory doing nothing — and until this badge existed there was
    /// nothing anywhere to say so.
    private var memoryNeedsAttention: Bool {
        memory.facts.contains { $0.verification == .pendingConfirmation }
    }

    /// Re-check authorization whenever the Coaching subpage appears, so a permission revoked in iOS
    /// Settings since the toggle was last touched still surfaces as "needs attention" instead of staying
    /// silently broken.
    private func refreshCheckInAuthorization() async {
        guard checkInOn else { return }
        checkInDenied = await !CoachCheckIn.isCurrentlyAuthorized()
    }
    @ObservedObject private var memory = CoachMemory.shared
    @ObservedObject private var semanticMemory = CoachSemanticMemory.shared
    /// The coach's identity (#R9) — name, avatar, tone. Observed so the `identityBar` row updates live.
    @ObservedObject private var identityStore = CoachIdentityStore.shared
    /// The structured goal (P3). The memory card's field still edits its title inline; the full editor
    /// with target/date/pace lives in the dedicated goal card.
    @ObservedObject private var goalStore = CoachGoalStore.shared
    @ObservedObject private var usage = CoachUsageLog.shared
    @State private var memoryExpanded: Bool = false
    /// The three independent Coach-entry points — see `CoachEntryPrefs` for why this replaced a single
    /// card/button/both picker.
    @AppStorage(CoachEntryPrefs.bannerKey) private var coachBannerEnabled = true
    @AppStorage(CoachEntryPrefs.headerIconKey) private var coachHeaderIconEnabled = true
    @AppStorage(CoachEntryPrefs.floatingButtonKey) private var coachFloatingButtonEnabled = true
    /// Master switch for the Coach's home-surface UI (#R7). Off hides all three entries above; card- and
    /// background-AI, and the coach settings themselves, are untouched.
    @AppStorage(CoachEntryPrefs.uiEnabledKey) private var coachUIEnabled = true
    /// Show the coach's avatar on the banner/header entries (#R11); off restores the plain sparkle icon.
    @AppStorage(CoachEntryPrefs.todayAvatarKey) private var todayAvatar = true
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
    /// Adding a fact by hand. The user knows their own constraints better than the coach infers them,
    /// and until now `add` was reachable only by the model.
    @State private var addingFact = false
    @State private var newFactText: String = ""
    @State private var newFactCategory: CoachMemory.Category = .other
    @State private var showMemoryCapacityAlert = false
    /// Which facts have their provenance row open — per fact, so opening one doesn't open all of them.
    @State private var expandedFactIDs: Set<UUID> = []
    /// Guards "Forget everything", which drops up to 120 facts irreversibly and used to fire on the tap.
    /// Two steps, not one: nothing here is recoverable, so the first asks and the second says what is
    /// actually being lost before it goes.
    @State private var showForgetAllConfirm = false
    @State private var showForgetAllFinalConfirm = false
    /// What the last "Summarise this chat now" tap actually did. Repeat taps on an already-processed
    /// chat are a no-op by design (they'd otherwise re-distil the same facts into duplicate memory
    /// entries), and a button that silently does nothing reads as a broken button — so it says so.
    @State private var summarizeOutcome: AICoachEngine.SummarizeOutcome?

    private let customModelTag = "__custom__"

    @ViewBuilder
    var body: some View {
        if usesHostNavigation {
            settingsContent
        } else {
            NavigationStack { settingsContent }
        }
    }

    private var settingsContent: some View {
        Group {
            if coach.isConfigured {
                hub
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        coachFeatureBar
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
        .onChangeCompat(of: coachFeatureEnabled) { enabled in
            // Existing chats, memory and all health data stay on device. Only future Coach surfaces
            // and automation stop; turning it back on restores the person's saved preferences.
            if !enabled {
                checkInOn = false
                CoachCheckIn.setEnabled(false)
            }
        }
        .navigationTitle("Coach settings")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !usesHostNavigation {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Edit fact", isPresented: editingBinding) {
            TextField("Fact", text: $editingFactText)
            Button("Cancel", role: .cancel) { editingFactID = nil }
            Button("Save") {
                if let id = editingFactID {
                    memory.update(id, text: editingFactText, confirmedByUser: true)
                }
                editingFactID = nil
            }
        }
        .sheet(isPresented: $addingFact) { addFactSheet }
    }

    /// Adding a fact by hand. Saved as the user's own words, so it is confirmed on the spot and can
    /// frame every reply the moment it's pinned — unlike an inference, which has to be asked about.
    private var addFactSheet: some View {
        NavigationStack {
            subpageScaffold {
                NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("One short sentence the coach should know about you — a constraint, an injury, how you like to train.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("Fact", text: $newFactText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1...4)
                            .padding(8)
                            .background(StrandPalette.surfaceInset,
                                        in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .accessibilityLabel("Fact")
                        Picker("Category", selection: $newFactCategory) {
                            ForEach(CoachMemory.Category.allCases, id: \.self) { category in
                                Text(LocalizedStringKey(category.label)).tag(category)
                            }
                        }
                        .pickerStyle(.menu)
                        .appleInspiredTint("coach")
                    }
                }
            }
            .navigationTitle("Add a fact")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { addingFact = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let saved = memory.add(newFactText,
                                               category: newFactCategory,
                                               source: .user,
                                               confirmedByUser: true)
                        if saved {
                            addingFact = false
                        } else {
                            showMemoryCapacityAlert = true
                        }
                    }
                    .disabled(newFactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Memory", isPresented: $showMemoryCapacityAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing was saved. Coach memory is full of pinned or more strongly verified facts. Remove one before trying again.")
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
                coachFeatureBar
                connectedHeader

                NavigationLink { connectionSubpage } label: {
                    NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
                    NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
                    NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
                    NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            attentionBadge(memoryNeedsAttention)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(memoryNeedsAttention ? "Needs attention" : "")

                NavigationLink { privacySubpage } label: {
                    NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background models")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("Optional cheaper models for chat summaries or a manually requested card read. You do not need to choose one for normal coaching, tools or saved facts.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
    /// empty means it falls back to the coaching model, but for Closer look empty means the feature is off and
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
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
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
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
            NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.allowEmoji)
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Emoji in replies")
            }
        }
    }

    /// Reply length — concise / normal / detailed. Same segmented-picker shape as `proactiveBar`; `normal`
    /// leaves today's replies unchanged, the other two steer via a prompt clause (`CoachVerbosity`).
    private var verbosityBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var memorySubpage: some View {
        subpageScaffold {
            memoryBar
            semanticMemoryBar
            if coach.dataConsent { memoryMaintenanceBar }
        }
        .navigationTitle("Memory")
    }

    private var semanticMemoryBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: semanticMemory.status.isModelLoaded
                          ? "brain.filled.head.profile" : "brain.head.profile")
                        .foregroundStyle(semanticMemory.isEnabled
                                         ? StrandPalette.accent : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Semantic memory")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Nomic finds related local text without uploading it. Health measurements still use exact local queries.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { semanticMemory.isEnabled },
                        set: { enabled in
                            semanticMemory.isEnabled = enabled
                            Task {
                                if enabled { await coach.prepareSemanticMemory() }
                                else { await semanticMemory.deleteIndex() }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .appleInspiredTint("coach")
                    .accessibilityLabel("Semantic memory")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model: Nomic Embed Text v2 (Q4_K_M, 256 dimensions)")
                    Text("Indexed: \(semanticMemory.status.indexedDocuments) · Pending: \(semanticMemory.status.pendingDocuments)")
                    Text("Index size: \(CoachMemoryFootprint.formatted(Int(semanticMemory.status.byteSize)))")
                    if let lastRun = semanticMemory.status.lastRunAt {
                        Text("Last local run: \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Text(semanticMemory.status.isModelLoaded
                         ? "Model is currently loaded and will unload after inactivity."
                         : "Model is not using memory right now.")
                    switch semanticMemory.lastRetrievalMode {
                    case .semantic:
                        Text("Last retrieval: semantic memory")
                    case .keywordFallback:
                        Text("Last retrieval: keyword fallback")
                    case .unavailable:
                        Text("Last retrieval: no matching memory used")
                    }
                    // How often the model actually beats the 2.5-second budget on THIS device, plus what the
                    // embedding and the cold load cost. Session-local, never stored, never sent — see
                    // CoachSemanticTelemetry. A losing race costs the whole semantic arm for that turn, so
                    // this rate is the number that says whether latency or ranking is the thing to fix.
                    if let telemetry = semanticMemory.telemetry.summary {
                        Text("This session: \(telemetry)")
                    }
                    if let error = semanticMemory.status.lastError, !error.isEmpty {
                        Text("Fallback active: \(error)")
                            .foregroundStyle(StrandPalette.statusCritical)
                    }
                }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(semanticMemory.isIndexing ? "Building index…" : "Indexing progress")
                        Spacer()
                        Text("\(semanticMemory.status.completionPercentage)%")
                            .monospacedDigit()
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    ProgressView(value: semanticMemory.status.completionFraction)
                        .appleInspiredTint("coach")
                        .accessibilityLabel("Semantic memory indexing progress")
                        .accessibilityValue("\(semanticMemory.status.completionPercentage) percent")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
                          alignment: .leading,
                          spacing: 8) {
                    if semanticMemory.isManualIndexing {
                        Button("Stop indexing") {
                            semanticMemory.cancelManualIndexing()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Continue indexing") {
                            Task { await coach.startManualSemanticIndexing() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(semanticMemory.status.pendingDocuments == 0)
                    }
                    Button("Rebuild index") {
                        Task { await semanticMemory.rebuild() }
                    }
                    .buttonStyle(.bordered)
                    Button("Delete index", role: .destructive) {
                        Task { await semanticMemory.deleteIndex() }
                    }
                    .buttonStyle(.bordered)
                    Button("Run model check") {
                        Task { await semanticMemory.runModelSelfTest() }
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(!semanticMemory.isEnabled)
                if let summary = semanticMemory.selfTestSummary {
                    Text(summary)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
            NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
                HStack(spacing: 10) {
                    Image(systemName: "switch.2")
                        .foregroundStyle(appleHealthColors
                                        ? CoachIconColors.color(for: "coach.settings.dataAccess") : StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Data access")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("Choose what the coach can fetch, log and remember.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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

    /// Most people choose one of three understandable modes. Expert settings exposes the underlying
    /// purpose gates without weakening them, including the separate sensitive-journal permission.
    private var dataAccessSubpage: some View {
        subpageScaffold {
            dataAccessExplanationBar
            dataAccessModeBar
            if dataAccessExpertMode || CoachDataAccessMode.current(for: coach.toolConsent.enabled) == .expert {
                coreBiometricsAccessBar
                longHistoryAccessBar
                workoutsAccessBar
                planningAccessBar
                stressAccessBar
                logsAccessBar
                sensitiveLogsAccessBar
                memoryToolsAccessBar
                onDeviceSignalsBar
            }
        }
        .navigationTitle("Data access")
    }

    /// Explains the boundary before showing switches. The provider receives only values returned through
    /// these locally checked paths; it cannot browse the database or raise its own permission level.
    private var dataAccessExplanationBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            VStack(alignment: .leading, spacing: 8) {
                Label("How this access is used", systemImage: "lock.shield")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Before each answer, NOOP checks your question and the privacy level below on this device. It selects only the relevant local summary, permitted tool result or approved text-memory match — for example a recent recovery trend for a recovery question.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your provider cannot browse your database, request a new permission, or receive raw sensor streams. Nomic searches approved text locally; it never receives numerical health histories. Long-term questions use compact aggregates only when Deep insights is allowed. Sensitive journal answers always need their own separate switch.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var dataAccessModeBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Privacy level")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Picker("Privacy level", selection: dataAccessModeBinding) {
                    Text("Essentials").tag(CoachDataAccessMode.essentials)
                    Text("Personal").tag(CoachDataAccessMode.personal)
                    Text("Deep insights").tag(CoachDataAccessMode.deepInsights)
                    Text("Expert").tag(CoachDataAccessMode.expert)
                }
                // Four translated labels do not fit reliably in one segmented row on an iPhone.
                // The menu retains the simple choice without making the labels tiny or truncated.
                .pickerStyle(.menu)
                Text(dataAccessModeDetail)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !dataAccessExpertMode && CoachDataAccessMode.current(for: coach.toolConsent.enabled) != .expert {
                    Button("Fine-tune access") { dataAccessExpertMode = true }
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var dataAccessModeBinding: Binding<CoachDataAccessMode> {
        Binding(
            get: { CoachDataAccessMode.current(for: coach.toolConsent.enabled) },
            set: { mode in
                if let purposes = mode.purposes {
                    coach.toolConsent.enabled = purposes
                    dataAccessExpertMode = false
                } else {
                    dataAccessExpertMode = true
                }
            }
        )
    }

    private var dataAccessModeDetail: String {
        switch CoachDataAccessMode.current(for: coach.toolConsent.enabled) {
        case .essentials:
            return "Core health, workouts, planning and memory."
        case .personal:
            return "Adds stress, ordinary logs and personal patterns."
        case .deepInsights:
            return "Adds compact long-term trends; sensitive journal data stays off."
        case .expert:
            return "Custom access choices. Sensitive journal data needs its own extra switch."
        }
    }

    /// Global feature opt-in. It intentionally lives at the top of the settings hub, not under the
    /// appearance-only Today controls, because this governs the whole Coach rather than one entry point.
    private var coachFeatureBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            Toggle(isOn: $coachFeatureEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable AI Coach")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coachFeatureEnabled
                         ? "Coach entry points and optional check-ins are available. Data sharing is still a separate choice."
                         : "Off by default. Turn this on after you choose to use a provider; chats and local data stay saved.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .appleInspiredTint("coach")
            .onChangeCompat(of: coachFeatureEnabled) { enabled in
                Task {
                    if enabled { await coach.prepareSemanticMemory() }
                    else { await coach.unloadSemanticMemory() }
                }
            }
        }
        .accessibilityHint("Turning this off hides Coach from the app and stops Coach check-ins. It does not delete chats or health data.")
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
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            HStack(spacing: 10) {
                Image(systemName: "heart.text.square")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.coreBiometrics)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Core biometrics")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Charge, sleep detail, readiness and charge drivers.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.coreBiometrics))
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Let the coach fetch core biometrics")
            }
        }
    }

    /// Deep time-series reads have their own opt-in: normal day-to-day coaching never needs a multi-year
    /// inventory, and a local routing match is not permission to examine it.
    private var longHistoryAccessBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            HStack(spacing: 10) {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.longHistory)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Long-term trend")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("A compact local trend across months or years")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.longHistory))
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Long-term trend")
            }
        }
    }

    private var workoutsAccessBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            HStack(spacing: 10) {
                Image(systemName: "figure.run")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.workouts)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Workouts")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Recent workouts, zone minutes and session outlook.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.workouts))
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Let the coach fetch workouts")
            }
        }
    }

    private var planningAccessBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.planning))
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Let the coach suggest and review sessions")
            }
        }
    }

    private var stressAccessBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.heart")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.stress)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stress")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Today's derived stress index.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.stress))
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Let the coach fetch the stress index")
            }
        }
    }

    private var logsAccessBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.clipboard")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.logs)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Logging")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Reading and logging caffeine, journal entries and Lab Book markers.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.logs))
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Let the coach read and log your entries")
            }
        }
    }

    /// A second affirmative choice for journal labels that can reveal sexual, relationship, illness or
    /// cannabis information. This never broadens ordinary Logs; it unlocks only the dedicated reader.
    private var sensitiveLogsAccessBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            HStack(spacing: 10) {
                Image(systemName: "lock.heart")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.sensitiveLogs)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sensitive journal")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Sexual, relationship, illness and cannabis entries need an extra choice.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.sensitiveLogs))
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Sensitive journal")
            }
        }
    }

    private var memoryToolsAccessBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(coach.toolConsent.enabled.contains(.memory)
                                     ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memory tools")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Saving, correcting and forgetting facts, and searching past chats.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: purposeBinding(.memory))
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Let the coach save and search memory")
            }
        }
    }

    /// Entry into the full how-the-coach-works / what's-shared page (#P6 6.2). A row, not buried text,
    /// so the transparency story is one tap from where consent is granted.
    private var howItWorksRow: some View {
        Button { showCoachInfo = true } label: {
            NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(appleHealthColors
                                        ? CoachIconColors.color(for: "coach.settings.howItWorks") : StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("How Coach works")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("What runs on \(Platform.deviceNounPhrase), what's sent, and why the model matters.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Coach UI master switch (#R7) — hides the home-surface entry points, keeps card/background AI

    private var coachVisibilityBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $coachUIEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show Coach on Today")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("Turn off to hide the Coach card and floating button. Per-metric “Ask coach” and the AI that writes your card summaries keep working.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .appleInspiredTint("coach")

                if coachUIEnabled {
                    Divider().overlay(StrandPalette.hairline)
                    Toggle(isOn: $todayAvatar) {
                        HStack(spacing: 10) {
                            CoachAvatarView(size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Show coach avatar")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("Use your coach’s picture on the Today entry instead of a plain icon.")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .appleInspiredTint("coach")
                }
            }
        }
    }

    // MARK: - Coach entry preference (iOS: card vs. draggable floating button vs. both)

    @ViewBuilder private var coachEntryBar: some View {
        #if os(iOS)
        if coachUIEnabled {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap")
                        .foregroundStyle(appleHealthColors
                                        ? CoachIconColors.color(for: "coach.settings.entry") : StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Coach entry")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text("How you open Coach from Today — pick any combination.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                // Three independent switches (not a single either/or picker) — a user can want the banner
                // AND the floating button, or the compact header icon on its own, in any combination.
                Toggle(isOn: $coachBannerEnabled) {
                    Text("Banner")
                    Text("A full-width card in Today's card list, movable via Arrange Today")
                }
                .accessibilityLabel("Coach entry: banner")
                Toggle(isOn: $coachHeaderIconEnabled) {
                    Text("Header icon")
                    Text("A compact avatar in Today's header (Liquid Today only)")
                }
                .accessibilityLabel("Coach entry: header icon")
                Toggle(isOn: $coachFloatingButtonEnabled) {
                    Text("Floating button")
                    Text("A draggable button that floats over every screen")
                }
                .accessibilityLabel("Coach entry: floating button")

                // Button placement only matters when the floating button is actually shown.
                if coachFloatingButtonEnabled {
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
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $fabLocked) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lock position")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Stops the button moving if you brush it. Tapping still opens Coach.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .appleInspiredTint("coach")
        }
    }
    #endif

    // MARK: - Memory maintenance (cheap-model summaries)

    private var memoryMaintenanceBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $coach.autoSummarize)
                        .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                        .accessibilityLabel("Summarise past chats automatically")
                }

                Text("Optional: turning this on sends a finished chat to your provider. Without it, saved facts and local chat history still remain on your device.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
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
            NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
            NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
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
            NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                                let usage = info.usageUSD.formatted(.currency(code: "USD"))
                                let ceiling = limit.formatted(.currency(code: "USD"))
                                Text(String(localized: "\(usage) of \(ceiling) used"))
                                    .font(StrandFont.footnote.monospacedDigit())
                                    .foregroundStyle(StrandPalette.textSecondary)
                            } else {
                                let usage = info.usageUSD.formatted(.currency(code: "USD"))
                                Text(String(localized: "\(usage) used — no limit set on this key"))
                                    .font(StrandFont.footnote.monospacedDigit())
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            Text("Lifetime for this key, straight from OpenRouter — not a weekly or monthly figure.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
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

    /// Answers whether the connection actually worked before the user's first real question.
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
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.dataConsent)
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Let the coach use my data")
            }
        }
    }

    private var onDeviceSignalsBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.includeOnDeviceSignals)
                    .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                    .accessibilityLabel("Also share my patterns and Lab Book with the coach")
            }
        }
    }

    // MARK: - Persona

    private var personaBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $morningSuggestionOn)
                        .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
                        .accessibilityLabel("Morning suggestion on Today")
                }
                if !(coach.isConfigured && coach.dataConsent) {
                    Text("Needs a connected provider and data access, so the coach has something to suggest from.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(!(coach.isConfigured && coach.dataConsent))
    }

    // MARK: - Daily check-in

    private var checkInBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $checkInOn)
                        .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
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
    /// says that it is still learning and uses the fixed time meanwhile — so the mode never looks
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
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $planReminderOn)
                        .labelsHidden().toggleStyle(.switch).appleInspiredTint("coach")
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
        let footprint = CoachMemoryFootprint.estimate(conversations: coach.conversations, facts: memory.facts)
        return NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                            // What these facts actually DO, rather than the old blanket claim that the
                            // coach "uses these in every reply" — which held for none of them: a normal
                            // fact rides only when it matches the question, and an unconfirmed one is
                            // barred from the always-on block however it was pinned.
                            Text(memory.facts.isEmpty
                                 ? String(localized: "What the coach remembers about you, across conversations.")
                                 : memoryReachSummary)
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 7) {
                                Label(CoachMemoryFootprint.formatted(footprint.totalBytes), systemImage: "internaldrive")
                                Label("\(coach.conversations.count)", systemImage: "bubble.left.and.bubble.right")
                                Label("\(memory.facts.count)", systemImage: "brain")
                            }
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
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
                        VStack(alignment: .leading, spacing: 10) {
                            // Grouped by what a fact IS, in the order that matches how much it needs the
                            // user: anything waiting on them first, then what frames every reply, then
                            // the rest. A flat 120-row list would give all of them the same weight.
                            ForEach(memoryGroups, id: \.title) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(LocalizedStringKey(group.title)).strandOverline()
                                    ForEach(group.facts) { fact in factRow(fact) }
                                }
                            }
                            memoryListActions
                        }
                    } else {
                        // Expanding onto nothing at all reads as a broken control (#coach-bugs): an empty
                        // memory is a normal state and has to SAY it's empty, and say how it fills.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Memory is empty").strandOverline()
                            Text("The coach hasn't saved anything about you yet. It adds a fact when you tell it something durable — an injury, a constraint, how you like to train — and \"Summarise past chats\" below distils older conversations into facts too. You can also add one yourself.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            addFactButton
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// The card's one-line honesty about how these facts reach the model. Split by actual reach rather
    /// than by a bare count, which never told anyone whether any of them were being used at all.
    private var memoryReachSummary: String {
        let reach = CoachMemory.reach(of: memory.facts)
        var parts: [String] = []
        if reach.alwaysOn > 0 {
            parts.append(String(localized: "\(reach.alwaysOn) frame every reply"))
        }
        if reach.whenRelevant > 0 {
            parts.append(String(localized: "\(reach.whenRelevant) come up when they're relevant"))
        }
        if reach.awaitingConfirmation > 0 {
            parts.append(String(localized: "\(reach.awaitingConfirmation) waiting for you to confirm"))
        }
        if reach.expired > 0 {
            parts.append(String(localized: "\(reach.expired) expired"))
        }
        guard !parts.isEmpty else {
            return String(localized: "What the coach remembers about you, across conversations.")
        }
        return parts.joined(separator: " · ")
    }

    /// One section per kind of fact. Unconfirmed first (they're waiting on the user), then the ones that
    /// frame every reply, then everything else by category, then expired — so the list leads with what
    /// needs the user rather than treating all 120 rows as equals.
    private var memoryGroups: [(title: String, facts: [CoachMemory.MemoryFact])] {
        let all = memory.facts
        let pending = all.filter { $0.verification == .pendingConfirmation && memory.isActive($0) }
        let expired = all.filter { !memory.isActive($0) }
        let alwaysOn = all.filter {
            memory.isActive($0) && $0.importance == .pinned && $0.verification == .confirmed
        }
        let handled = Set(pending.map(\.id)).union(expired.map(\.id)).union(alwaysOn.map(\.id))
        let rest = all.filter { !handled.contains($0.id) }

        var groups: [(String, [CoachMemory.MemoryFact])] = []
        if !pending.isEmpty { groups.append(("Waiting for your confirmation", pending)) }
        if !alwaysOn.isEmpty { groups.append(("Frames every reply", alwaysOn)) }
        for category in CoachMemory.Category.allCases {
            let inCategory = rest.filter { $0.category == category }
            if !inCategory.isEmpty { groups.append((category.label, inCategory)) }
        }
        if !expired.isEmpty { groups.append(("Expired", expired)) }
        return groups
    }

    @ViewBuilder
    private func factRow(_ fact: CoachMemory.MemoryFact) -> some View {
        let isExpanded = expandedFactIDs.contains(fact.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: fact.category.symbol)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Text(fact.text)
                    .font(StrandFont.footnote)
                    .foregroundStyle(memory.isActive(fact)
                                     ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if fact.verification != .confirmed {
                    Button {
                        memory.confirm(fact.id)
                    } label: {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Confirm: \(fact.text)")
                }
                // Pinning was the model's decision alone: `importance` had no control anywhere, so a
                // user who knew a constraint must frame every reply couldn't say so.
                Button {
                    memory.setImportance(fact.id, fact.importance == .pinned ? .normal : .pinned)
                } label: {
                    Image(systemName: fact.importance == .pinned ? "pin.fill" : "pin")
                        .foregroundStyle(fact.importance == .pinned
                                         ? StrandPalette.accent : StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(fact.importance == .pinned
                                    ? "Unpin: \(fact.text)" : "Pin: \(fact.text)")
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

            // Provenance was recorded from the start — where a fact came from, how many times it's been
            // observed, what it used to say — and shown nowhere, so "why does the coach think this?" had
            // no answer. Behind a disclosure: it's the second question, not the first.
            Button {
                withAnimation(StrandMotion.fade) {
                    if isExpanded { expandedFactIDs.remove(fact.id) } else { expandedFactIDs.insert(fact.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(isExpanded ? "Hide details" : "Details")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)

            if isExpanded { factProvenance(fact) }
        }
    }

    @ViewBuilder
    private func factProvenance(_ fact: CoachMemory.MemoryFact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            factSourceLine(fact.source)
            Text("First saved \(fact.createdAt.formatted(date: .abbreviated, time: .omitted))")
            Text("\(fact.evidenceCount) observation(s)")
            if let previous = fact.revisions.last?.previousText {
                Text("Previously: \(previous)")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let until = fact.validUntil {
                Text(memory.isActive(fact)
                     ? String(localized: "Expires \(until.formatted(date: .abbreviated, time: .omitted))")
                     : String(localized: "Expired \(until.formatted(date: .abbreviated, time: .omitted))"))
            }
            if fact.sensitivity == .health {
                Text("Treated as health information.")
            }
            // The expiry is editable here rather than only by the coach: a fact the user knows is over
            // shouldn't need a conversation to retire.
            HStack(spacing: 12) {
                if fact.validUntil != nil {
                    Button("Remove expiry") { memory.setValidUntil(fact.id, nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                }
                Button("Expire today") { memory.setValidUntil(fact.id, Date()) }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
            }
            .font(StrandFont.caption)
            .padding(.top, 2)
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.leading, 22)
    }

    /// Where a fact came from, in the user's terms — literal `Text` per case for the i18n scanner.
    @ViewBuilder
    private func factSourceLine(_ source: CoachMemory.Source) -> some View {
        switch source {
        case .user:                Text("You told the coach this.")
        case .coachTool:           Text("The coach saved this during a conversation.")
        case .conversationSummary: Text("Distilled from a past conversation.")
        case .legacy:              Text("Saved before the coach recorded where facts came from.")
        }
    }

    private var addFactButton: some View {
        Button {
            newFactText = ""
            newFactCategory = .other
            addingFact = true
        } label: {
            Label("Add a fact", systemImage: "plus.circle")
                .font(StrandFont.footnote)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.accent)
        .accessibilityLabel("Add a fact to coach memory")
    }

    private var memoryListActions: some View {
        HStack {
            addFactButton
            Spacer()
            Button {
                showForgetAllConfirm = true
            } label: {
                Label("Forget everything", systemImage: "trash")
                    .font(StrandFont.footnote)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.accent)
            .accessibilityLabel("Forget all remembered facts")
            // Up to 120 facts, gone for good, on a single tap — the only other irreversible control on
            // this screen ("Forget saved key") has asked first all along.
            .confirmationDialog("Forget everything the coach remembers?",
                                isPresented: $showForgetAllConfirm,
                                titleVisibility: .visible) {
                Button("Forget everything", role: .destructive) { showForgetAllFinalConfirm = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(memory.facts.count) fact(s) will be deleted. This can't be undone — the coach will have to learn them again.")
            }
        }
        // The second ask, on the enclosing row rather than on the button: two presentations from one
        // view fight over the same slot, and the first has to be gone before this one arrives.
        //
        // It is not a repeat of the first. Nothing here is recoverable — there is no archive for facts
        // as there is for conversations — so the last step names what is actually at stake rather than
        // asking the same question twice: the facts that frame every reply are injuries and hard
        // constraints, the ones the coach cannot rebuild from data and the user would have to remember
        // to say again.
        .alert("Really forget everything?", isPresented: $showForgetAllFinalConfirm) {
            Button("Forget permanently", role: .destructive) { memory.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(forgetAllFinalWarning)
        }
    }

    /// The last warning before the memory is gone. Leads with the always-on facts when there are any,
    /// because those are the costly half — a preference the coach can pick up again from the next
    /// conversation, an injury it cannot.
    private var forgetAllFinalWarning: String {
        let alwaysOn = CoachMemory.reach(of: memory.facts).alwaysOn
        guard alwaysOn > 0 else {
            return String(localized: "There is no undo, and no archive. The coach starts again from nothing.")
        }
        return String(localized: "\(alwaysOn) of them frame every reply — injuries and hard constraints you'd have to tell the coach again. There is no undo, and no archive.")
    }

    // MARK: - System prompt

    private var systemPromptBar: some View {
        NoopCard(padding: 14, cornerRadius: NoopMetrics.groupedRadius) {
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
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
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
            .appleInspiredTint("coach")
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
                .foregroundStyle(StrandPalette.textSecondary)
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
