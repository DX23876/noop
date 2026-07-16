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
    @State private var checkInOn: Bool = CoachCheckIn.isEnabled
    @State private var checkInTime: Date = CoachCheckIn.timeAsDate
    @State private var checkInDenied: Bool = false
    @ObservedObject private var memory = CoachMemory.shared
    /// The structured goal (P3). The memory card's field still edits its title inline; the full editor
    /// with target/date/pace lives in the dedicated goal card.
    @ObservedObject private var goalStore = CoachGoalStore.shared
    @State private var memoryExpanded: Bool = false
    @State private var goalDraft: String = ""
    /// How the user reaches Coach from Today: the card, the draggable floating button, or both.
    @AppStorage(CoachEntryMode.storageKey) private var coachEntryModeRaw = CoachEntryMode.both.rawValue
    /// Which corner the floating button is pinned to (`.custom` once dragged), and whether it's locked.
    @AppStorage(CoachButtonCorner.storageKey) private var fabCornerRaw = CoachButtonCorner.bottomTrailing.rawValue
    @AppStorage(CoachButtonCorner.lockedKey) private var fabLocked = false
    /// In-place fact editing: the fact being edited + its working text.
    @State private var editingFactID: UUID?
    @State private var editingFactText: String = ""

    private let customModelTag = "__custom__"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if coach.isConfigured {
                        connectedHeader
                        consentBar
                        if coach.dataConsent { onDeviceSignalsBar }
                        personaBar
                        coachEntryBar
                        checkInBar
                        memoryBar
                        if coach.dataConsent { memoryMaintenanceBar }
                        systemPromptBar
                        disconnectRow
                    } else {
                        setupCard
                    }
                    privacyFootnote
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
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

    // MARK: - Memory

    private var memoryBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: memoryExpanded ? 10 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) {
                        memoryExpanded.toggle()
                        if memoryExpanded { goalDraft = goalStore.goal?.title ?? "" }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "brain")
                            .foregroundStyle(memory.facts.isEmpty && goalStore.goal == nil
                                             ? StrandPalette.textTertiary : StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Coach memory")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(memory.facts.isEmpty
                                 ? "Your goal and what the coach remembers about you, across conversations."
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("My goal").strandOverline()
                        TextField("e.g. Half marathon in October", text: $goalDraft)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .onChangeCompat(of: goalDraft) { newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty {
                                    goalStore.clear()
                                } else if var existing = goalStore.goal {
                                    existing.title = newValue
                                    goalStore.goal = existing
                                } else {
                                    goalStore.goal = CoachGoal(kind: .custom, title: newValue)
                                }
                            }
                            .accessibilityLabel("My training goal")
                    }

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

                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").strandOverline()
                    Picker("Provider", selection: $coach.provider) {
                        ForEach(AIProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
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
        }
    }

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
                .disabled(!coach.hasKey)
                .help("Fetch the available models from \(coach.provider.displayName) using your saved key")
                .accessibilityLabel("Refresh models from provider")
            }

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

            if customModel {
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

    private var modelPickerSelection: Binding<String> {
        Binding(
            get: { customModel ? customModelTag : coach.model },
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
