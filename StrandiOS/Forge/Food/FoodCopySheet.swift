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
    @State private var chosen: Set<DateComponents> = []
    /// Monday to Friday to start with, in the calendar's numbering (1 = Sunday).
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var until: Date = .now

    private static let components: Set<Calendar.Component> = [.calendar, .era, .year, .month, .day]

    private var shownDay: Date { WeightSeries.date(forDay: model.day) ?? .now }

    /// The weekday numbers in the order this calendar starts its week.
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private var chosenDays: [String] {
        chosen.compactMap { Calendar.current.date(from: $0).map(Repository.localDayKey) }.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MultiDatePicker("Days", selection: $chosen)
                } footer: {
                    Text("Days chosen: \(chosen.count)")
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
                ToolbarItem(placement: .confirmationAction) { Button("Copy", action: copy).disabled(chosen.isEmpty) }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: start)
    }

    private func weekdayToggle(_ weekday: Int) -> some View {
        let on = weekdays.contains(weekday)
        let name = Calendar.current.standaloneWeekdaySymbols[weekday - 1]
        return Button {
            if on { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
        } label: {
            Text(Calendar.current.veryShortStandaloneWeekdaySymbols[weekday - 1])
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
        until = Calendar.current.date(byAdding: .day, value: 28, to: shownDay) ?? shownDay
    }

    private func selectRepeat() {
        let days = FoodLog.repeatDays(after: model.day, through: Repository.localDayKey(until), weekdays: weekdays)
        for day in days {
            guard let date = WeightSeries.date(forDay: day) else { continue }
            chosen.insert(Calendar.current.dateComponents(Self.components, from: date))
        }
    }

    private func cancel() { dismiss() }
    private func copy() { Task { await model.copy(batch.entries, toDays: chosenDays, repo: repo); dismiss() } }
}
#endif
