#if os(iOS)
import SwiftUI
import StrandCore
import StrandAnalytics

/// The day the Food page shows: the day before and after a tap away, the date itself opens a calendar, and a
/// way back to today whenever another day is shown (owner, 2026-11-25). Swiping and the week strip still work.
struct FoodDayPicker: View {
    @Bindable var model: ForgeFoodModel
    @State private var choosing = false

    static func title(_ day: String, today: Date = .now) -> String {
        if day == Repository.localDayKey(today) { return String(localized: "Today") }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today),
           day == Repository.localDayKey(yesterday) { return String(localized: "Yesterday") }
        guard let date = WeightSeries.date(forDay: day) else { return day }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button("Previous day", systemImage: "chevron.left") { model.shiftDay(by: -1) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            Spacer(minLength: 0)
            Button { choosing = true } label: {
                HStack(spacing: 6) {
                    Text(Self.title(model.day)).font(.headline).foregroundStyle(ForgeColor.text)
                    Image(systemName: "calendar").font(.subheadline).foregroundStyle(ForgeColor.secondary)
                }
                .frame(minHeight: 44)
            }
            .accessibilityHint(Text("Choose a day"))
            if !model.isToday {
                Button("Today") { model.day = Repository.localDayKey(.now) }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(ForgeColor.accent.opacity(0.15)))
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            Button("Next day", systemImage: "chevron.right") { model.shiftDay(by: 1) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }
        .tint(ForgeColor.accent)
        .buttonStyle(.plain)
        .foregroundStyle(ForgeColor.accent)
        .animation(.easeOut(duration: 0.2), value: model.isToday)
        .sheet(isPresented: $choosing) {
            NavigationStack {
                DatePicker("Choose a day", selection: chosenDate, in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.locale, AppLanguage.activeLocale)
                    .padding(.horizontal, 16)
                    .navigationTitle("Choose a day")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { choosing = false } } }
                Spacer(minLength: 0)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// The shown day as a date for the calendar, written back as the local day key the page reads.
    private var chosenDate: Binding<Date> {
        Binding(get: { WeightSeries.date(forDay: model.day) ?? .now },
                set: { model.day = Repository.localDayKey($0) })
    }
}
#endif
