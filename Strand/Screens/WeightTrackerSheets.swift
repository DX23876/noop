import SwiftUI
import StrandAnalytics
import StrandDesign
import StrandCore

// The weight page's two sheets (owner decisions 2026-11-26): a date the wearer wants a forecast for, and the page's
// settings in one place: what a forecast starts from and runs at, the milestone spacing, which cards show, and the
// weigh-in reminder.

/// A date being added or edited. `Identifiable` so `.sheet(item:)` rebuilds for each.
struct WeightEventDraft: Identifiable {
    var id: String
    var name: String
    var date: Date
    var isExisting: Bool

    init() {
        id = UUID().uuidString; name = ""
        date = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        isExisting = false
    }

    init(event: WeightTracker.Event) {
        id = event.id; name = event.name
        date = WeightSeries.date(forDay: event.day) ?? Date()
        isExisting = true
    }
}

struct WeightEventSheet: View {
    @State var draft: WeightEventDraft
    let onSave: (WeightEventDraft) async -> Void
    let onDelete: (() async -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(draft: WeightEventDraft, onSave: @escaping (WeightEventDraft) async -> Void, onDelete: (() async -> Void)?) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var trimmed: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like Holiday", text: $draft.name)
                    DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                } footer: {
                    Text("NOOP shows what you are likely to weigh on this day, and afterwards what you did weigh.")
                }
                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            Task { await onDelete(); dismiss() }
                        } label: { Text("Delete date").frame(maxWidth: .infinity) }
                    }
                }
            }
            .navigationTitle(draft.isExisting ? Text("Edit date") : Text("New date"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = draft
                        saved.name = trimmed
                        Task { await onSave(saved); dismiss() }
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
    }
}

struct WeightSettingsSheet: View {
    @State private var stored: WeightTracker.Stored
    let rates: WeightTracker.Rates?
    let units: UnitSystem
    let onSave: (WeightTracker.Stored) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var manualOn: Bool
    @State private var manualKg: Double
    @State private var reminderOn = BodyMeasurementReminder.dailyEnabled
    @State private var reminderTime: Date
    @State private var reminderDays = BodyMeasurementReminder.dailyWeekdays
    @State private var reminderDenied = false

    init(stored: WeightTracker.Stored, rates: WeightTracker.Rates?, units: UnitSystem,
         onSave: @escaping (WeightTracker.Stored) async -> Void) {
        _stored = State(initialValue: stored)
        self.rates = rates
        self.units = units
        self.onSave = onSave
        _manualOn = State(initialValue: stored.settings.manualWishKgPerWeek != nil)
        _manualKg = State(initialValue: stored.settings.manualWishKgPerWeek ?? -0.5)
        let minutes = BodyMeasurementReminder.dailyMinutes
        _reminderTime = State(initialValue: Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60,
                                                                  second: 0, of: Date()) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Start from", selection: $stored.settings.basis) {
                        Text("The trend").tag(WeightTracker.TrendBasis.trend)
                        Text("Lowest weigh-in of 10 days").tag(WeightTracker.TrendBasis.tenDayLow)
                    }
                    Picker("Rate", selection: $stored.settings.rateMode) {
                        Text("Current").tag(WeightTracker.RateMode.current)
                        Text("Overall").tag(WeightTracker.RateMode.overall)
                        Text("Plan").tag(WeightTracker.RateMode.wish)
                    }
                    Picker("Current rate over", selection: $stored.settings.rateWindowDays) {
                        ForEach(WeightTracker.Settings.rateWindows, id: \.self) { Text("\($0) days").tag($0) }
                    }
                } header: {
                    Text("Forecast")
                } footer: {
                    Text("The lowest weigh-in of ten days leaves out water swings. Goal progress and changes always use the trend.")
                }
                Section {
                    Toggle("My own plan rate", isOn: $manualOn)
                    if manualOn {
                        Stepper(value: $manualKg, in: -1.5...1.0, step: 0.1) {
                            Text("\(signedMass(manualKg)) a week")
                        }
                    }
                } header: {
                    Text("Plan rate")
                } footer: {
                    Text("Used when neither a diet plan nor a goal date gives one.")
                }
                Section("Stops on the way") {
                    Picker("Spacing", selection: $stored.settings.milestoneStepKg) {
                        Text("Automatic").tag(Double?.none)
                        ForEach(WeightTracker.Settings.milestoneSteps, id: \.self) { step in
                            Text(UnitFormatter.massFromKilograms(step, system: units)).tag(Optional(step))
                        }
                    }
                }
                Section("Cards") {
                    ForEach(WeightTracker.Card.allCases, id: \.self) { card in
                        Toggle(cardLabel(card), isOn: Binding(
                            get: { !stored.settings.hiddenCards.contains(card.rawValue) },
                            set: { on in
                                stored.settings.hiddenCards.removeAll { $0 == card.rawValue }
                                if !on { stored.settings.hiddenCards.append(card.rawValue) }
                            }))
                    }
                }
                Section {
                    Toggle("Remind me to weigh in", isOn: $reminderOn)
                    if reminderOn {
                        DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                        weekdayPicker
                    }
                } header: {
                    Text("Reminder")
                } footer: {
                    if reminderDenied {
                        Text("Notifications are off for NOOP. Turn them on in the system settings.")
                    } else {
                        Text("It stays quiet on a day you already weighed in.")
                    }
                }
            }
            .navigationTitle(Text("Weight settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { Task { await save() } } }
            }
        }
    }

    /// Seven toggles, Monday first; none chosen means every day.
    private var weekdayPicker: some View {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols   // Sunday first
        let order = [2, 3, 4, 5, 6, 7, 1]
        return HStack(spacing: 6) {
            ForEach(order, id: \.self) { day in
                let on = reminderDays.isEmpty || reminderDays.contains(day)
                Button {
                    var next = reminderDays.isEmpty ? Set(1...7) : reminderDays
                    if next.contains(day) { next.remove(day) } else { next.insert(day) }
                    reminderDays = next.count == 7 ? [] : next
                } label: {
                    Text(symbols[day - 1]).font(StrandFont.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(on ? WeightDetailView.weightTint.opacity(0.18) : StrandPalette.surfaceBase,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(on ? WeightDetailView.weightTint : StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Calendar.current.standaloneWeekdaySymbols[day - 1]))
                .accessibilityValue(on ? Text("On") : Text("Off"))
            }
        }
    }

    private func cardLabel(_ card: WeightTracker.Card) -> LocalizedStringKey {
        switch card {
        case .milestones: "Stops on the way"
        case .forecast: "Forecast"
        case .events: "Your dates"
        case .changes: "Change"
        case .week: "This week"
        case .chart: "History chart"
        case .reports: "Reports"
        }
    }

    private func signedMass(_ kg: Double) -> String {
        let formatted = UnitFormatter.massFromKilograms(abs(kg), system: units)
        return kg > 0.05 ? "+" + formatted : kg < -0.05 ? "−" + formatted : formatted
    }

    private func save() async {
        stored.settings.manualWishKgPerWeek = manualOn ? (manualKg * 10).rounded() / 10 : nil
        let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        BodyMeasurementReminder.dailyMinutes = (parts.hour ?? 7) * 60 + (parts.minute ?? 0)
        BodyMeasurementReminder.dailyWeekdays = reminderDays
        if reminderOn != BodyMeasurementReminder.dailyEnabled {
            let outcome = await withCheckedContinuation { (done: CheckedContinuation<BodyMeasurementReminder.Outcome, Never>) in
                BodyMeasurementReminder.setEnabled(reminderOn, daily: true) { done.resume(returning: $0) }
            }
            if outcome == .denied { reminderDenied = true; reminderOn = false }
        } else {
            BodyMeasurementReminder.refresh()
        }
        await onSave(stored)
        if !reminderDenied { dismiss() }
    }
}
