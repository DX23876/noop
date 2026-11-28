#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandCore

/// Copy entries to days picked in a calendar (Bevel's "copy to today, tomorrow or several days"). A repeat
/// fills in chosen weekdays up to a date, so one breakfast goes to every weekday for months at a time
/// (tester request 2026-11-28); single days are then ticked or unticked in the calendar.
struct FoodCopySheet: View {
    let batch: FoodEntryBatch
    let model: ForgeFoodModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    /// The calendar the picker builds its own selection with, so a day filled in by a repeat is the same value as
    /// the picker's when it is tapped again.
    @Environment(\.calendar) private var calendar
    @State private var chosen: Set<DateComponents> = []
    /// Monday to Friday to start with, in the calendar's numbering (1 = Sunday).
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var until: Date = .now

    private static let components: Set<Calendar.Component> = [.calendar, .era, .year, .month, .day]

    private var shownDay: Date { WeightSeries.date(forDay: model.day) ?? .now }

    /// The weekday numbers in the order this calendar starts its week.
    private var orderedWeekdays: [Int] {
        let first = calendar.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    /// The chosen days once each, never the shown day itself: copying a meal onto its own day only doubles it.
    private var chosenDays: [String] {
        Set(chosen.compactMap(dayKey)).subtracting([model.day]).sorted()
    }

    private func dayKey(_ components: DateComponents) -> String? {
        calendar.date(from: components).map(Repository.localDayKey)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MultiDatePicker("Days", selection: $chosen)
                } footer: {
                    Text("Days chosen: \(chosenDays.count)")
                }
                Section {
                    HStack(spacing: 6) {
                        ForEach(orderedWeekdays, id: \.self) { weekday in
                            weekdayToggle(weekday)
                        }
                    }
                    DatePicker("Until", selection: $until, in: shownDay..., displayedComponents: .date)
                    Button("Select these days", action: selectRepeat).disabled(weekdays.isEmpty)
                } header: {
                    Text("Repeat")
                } footer: {
                    Text("Selects every ticked weekday after this day up to the date. Untick single days in the calendar.")
                }
            }
            .navigationTitle("Copy to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Copy", action: copy).disabled(chosenDays.isEmpty) }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: start)
        .onChange(of: chosen) { _, picked in
            let tidy = tidied(picked)
            if tidy != picked { chosen = tidy }
        }
    }

    private func weekdayToggle(_ weekday: Int) -> some View {
        let on = weekdays.contains(weekday)
        let name = calendar.standaloneWeekdaySymbols[weekday - 1]
        return Button {
            if on { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
        } label: {
            Text(calendar.veryShortStandaloneWeekdaySymbols[weekday - 1])
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(on ? ForgeColor.onAccent : ForgeColor.text)
                .background(on ? ForgeColor.accent : ForgeColor.fill, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Four weeks ahead to start with.
    private func start() {
        until = calendar.date(byAdding: .day, value: 28, to: shownDay) ?? shownDay
    }

    /// One entry per day and none on the shown day, whichever way a day got into the selection.
    private func tidied(_ picked: Set<DateComponents>) -> Set<DateComponents> {
        var seen: Set<String> = [model.day]
        return picked.filter { components in
            guard let key = dayKey(components) else { return false }
            return seen.insert(key).inserted
        }
    }

    private func selectRepeat() {
        let days = FoodLog.repeatDays(after: model.day, through: Repository.localDayKey(until), weekdays: weekdays,
                                      calendar: calendar)
        let already = Set(chosen.compactMap(dayKey))
        for day in days where !already.contains(day) {
            guard let date = WeightSeries.date(forDay: day) else { continue }
            chosen.insert(calendar.dateComponents(Self.components, from: date))
        }
    }

    private func cancel() { dismiss() }
    private func copy() { Task { await model.copy(batch.entries, toDays: chosenDays, repo: repo); dismiss() } }
}
#endif
