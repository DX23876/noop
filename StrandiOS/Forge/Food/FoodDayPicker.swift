#if os(iOS)
import SwiftUI
import StrandCore
import StrandAnalytics

/// The day the Food page shows, with the day before and after a tap away.
struct FoodDayPicker: View {
    let model: ForgeFoodModel

    static func title(_ day: String) -> String {
        if day == Repository.localDayKey(.now) { return String(localized: "Today") }
        guard let date = WeightSeries.date(forDay: day) else { return day }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
    }

    var body: some View {
        HStack {
            Button("Previous day", systemImage: "chevron.left", action: previous)
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            Spacer()
            Text(Self.title(model.day)).font(.headline).foregroundStyle(ForgeColor.text)
            Spacer()
            Button("Next day", systemImage: "chevron.right", action: next)
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }
        .tint(ForgeColor.accent)
        .bold()
    }

    private func previous() { model.shiftDay(by: -1) }
    private func next() { model.shiftDay(by: 1) }
}
#endif
