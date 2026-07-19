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
    /// Presented sheet from the goal card: the editor, "set a new goal", or the Journey page. One
    /// enum-driven `.sheet(item:)` rather than three stacked `.sheet(isPresented:)` modifiers — which
    /// don't compose reliably (#R2; same fix `CoachView.ActiveSheet` already applies), and were the
    /// actual cause of "Set Goal does nothing / sometimes crashes": five independent presentation
    /// modifiers lived on one view node (`goalBar`), fed by buttons split across two sibling views
    /// (`goalBar` and `expiredGoalCard`). Hosted on the shared parent `goalJourneySubpage` so both
    /// views' buttons write into the same state the modifiers observe.
    private enum GoalSheet: Int, Identifiable {
        case edit, newGoal, journey
        var id: Int { rawValue }
    }
    @State private var goalSheet: GoalSheet?
    /// Same consolidation for the two confirmation dialogs.
    private enum GoalConfirmation: Int, Identifiable {
        case setAside, delete
        var id: Int { rawValue }
    }
    @State private var goalConfirmation: GoalConfirmation?

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
            backgroundModelsSection
            tokenUsageBar
            disconnectRow
        }
        .navigationTitle("Connection & model")
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background models")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("Cheaper models for background jobs — leave blank to use \(coach.provider.displayName)'s small model. Keeps the pricey coaching model for the actual conversation.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                roleModelField(
                    title: "Chat summaries",
                    caption: "Distils a finished chat so the coach can recall it later.",
                    text: $coach.memoryModel,
                    accessibility: "Chat-summary model id"
                )
                roleModelField(
                    title: "Card analyses",
                    caption: "A short read when you ask the coach about one health card.",
                    text: $coach.cardModel,
                    accessibility: "Card-analysis model id"
                )
            }
        }
    }

    /// One labelled model-id field for a background role. Empty = use the provider default, shown as the
    /// grey placeholder (the actual cheap model id), so the field distinguishes unset (default) from a
    /// deliberate override without a separate control.
    private func roleModelField(title: LocalizedStringKey, caption: LocalizedStringKey,
                                text: Binding<String>, accessibility: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).strandOverline()
            TextField(coach.provider.cheapModel.isEmpty ? "Same as coaching model" : coach.provider.cheapModel,
                      text: text)
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
                .accessibilityLabel(accessibility)
            Text(caption)
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A passed target date surfaces as a decision card here, not a dead-end footnote. Hosts the ONE
    /// enum-driven sheet + ONE enum-driven confirmation dialog for the whole goal card (#R2) — both
    /// `expiredGoalCard`'s and `goalBar`'s buttons below write into `goalSheet`/`goalConfirmation`.
    private var goalJourneySubpage: some View {
        subpageScaffold {
            expiredGoalCard
            goalBar
        }
        .navigationTitle("Goal & Journey")
        .sheet(item: $goalSheet) { which in
            switch which {
            case .edit:    CoachGoalEditorView(isOnboarding: false)
            case .newGoal: CoachGoalEditorView(isOnboarding: false, startsFresh: true)
            case .journey: JourneyView().environmentObject(coach)
            }
        }
        .confirmationDialog(goalConfirmationTitle,
                            isPresented: goalConfirmationIsPresented,
                            titleVisibility: .visible) {
            goalConfirmationActions
        } message: {
            goalConfirmationMessage
        }
    }

    private var goalConfirmationIsPresented: Binding<Bool> {
        Binding(get: { goalConfirmation != nil }, set: { if !$0 { goalConfirmation = nil } })
    }

    private var goalConfirmationTitle: LocalizedStringKey {
        switch goalConfirmation {
        case .setAside: return "Set this goal aside?"
        case .delete:   return "Delete this goal?"
        case nil:       return ""
        }
    }

    @ViewBuilder
    private var goalConfirmationActions: some View {
        switch goalConfirmation {
        case .setAside:
            Button("Injury or health") { goalStore.setAside(reason: "injury or health") }
            Button("Life got busy") { goalStore.setAside(reason: "life got busy") }
            Button("Priorities changed") { goalStore.setAside(reason: "priorities changed") }
            Button("No particular reason") { goalStore.setAside(reason: "") }
            Button("Cancel", role: .cancel) {}
        case .delete:
            Button("Delete goal", role: .destructive) { goalStore.clear() }
            Button("Cancel", role: .cancel) {}
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var goalConfirmationMessage: some View {
        switch goalConfirmation {
        case .setAside: Text("It stays in your history — nothing is lost, and there's nothing to justify.")
        case .delete:   Text("This removes the goal and its history from the device. There is no undo.")
        case nil:       EmptyView()
        }
    }

    private var coachingSubpage: some View {
        subpageScaffold {
            personaBar
            emojiBar
            coachEntryBar
            morningSuggestionBar
            proactiveBar
            checkInBar
            planReminderBar
        }
        .navigationTitle("Coaching")
        .task { await refreshCheckInAuthorization() }
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

    /// How chatty the coach is UNPROMPTED (#P10 10.4) — proactive messages cost tokens, so this is a
    /// user dial: off / only important / normal.
    private var proactiveBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(coach.proactiveLevel == .off ? StrandPalette.textTertiary : StrandPalette.accent)
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
            if coach.dataConsent { onDeviceSignalsBar }
            dataTransparencyNote
            systemPromptBar
        }
        .navigationTitle("Privacy & data")
    }

    /// Entry into the full how-the-coach-works / what's-shared page (#P6 6.2). A row, not buried text,
    /// so the transparency story is one tap from where consent is granted.
    private var howItWorksRow: some View {
        Button { showCoachInfo = true } label: {
            NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(StrandPalette.accent)
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

                Text("The model this uses lives under Connection & model → Background models.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

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
                // `+` string concatenation types the whole thing as plain `String`, which
                // `.accessibilityLabel(String)` never runs through the catalog — String(localized:)
                // interpolation is what actually localizes the static wrapper text around the two
                // dynamic, already-computed pieces.
                .accessibilityLabel(String(localized: "Last question token usage. \(CoachUsageLog.summaryLine(for: turn)). \(CoachUsageLog.cacheVerdict(for: turn))"))
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
                        .foregroundStyle(StrandPalette.accent)
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
                    goalSheet = goalIsClosed ? .newGoal : .edit
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: goalStore.goal?.status == .achieved ? "checkmark.seal.fill" : "target")
                            .foregroundStyle(goalStore.goal == nil ? StrandPalette.textTertiary : StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            // The fallback branch is a fixed literal; the other is the user's own free
                            // text — String(localized:) resolves the former without touching the latter.
                            Text(goalStore.goal?.title.isEmpty == false
                                 ? goalStore.goal!.title
                                 : String(localized: "Set a goal"))
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
                    Button { goalSheet = .journey } label: {
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
    }

    /// A goal must be able to END: close it as reached, set it aside, or delete it entirely.
    /// Before this row existed, `save()` forcing `.active` meant a goal could only ever be edited.
    private var goalLifecycleRow: some View {
        HStack(spacing: 16) {
            if goalStore.goal?.status == .active || goalStore.goal?.status == .paused {
                Button("Mark as achieved") { goalStore.markAchieved() }
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                Button("Set aside") { goalConfirmation = .setAside }
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            } else {
                Button("Set a new goal") { goalSheet = .newGoal }
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
            }
            Spacer(minLength: 8)
            Button { goalConfirmation = .delete } label: {
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
                        Button("Extend the date") { goalSheet = .edit }
                            .foregroundStyle(StrandPalette.accent)
                        Button("Set aside") { goalConfirmation = .setAside }
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
