import SwiftUI
import StrandDesign

/// When the strap alarm next buzzes, as a small line in Today's header: "tomorrow 06:00".
///
/// Shows nothing when the alarm is off or will not reach the strap: a line on Today is a promise, and an
/// alarm that never buzzes has none to make. It resolves through `NextStrapAlarm`, the resolver the Alarms
/// screen uses, and formats through the Clock setting, so the two screens cannot disagree on the moment
/// or on how it reads. Its own leaf with its own minute tick, so neither the clock nor the alarm settings
/// re-render Today.
///
/// Display only: it sits beside the date button, and a second tap target there would catch taps meant for
/// the date. Where the full phrase does not fit (a long language, a 12-hour clock, a small phone), it first
/// steps down one text size, then drops the day word and keeps the bell and the time.
struct TodayNextAlarmLine: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { tick in
            if let fire = NextStrapAlarm.date(enabled: behavior.smartAlarmEnabled,
                                              willArm: NextStrapAlarm.willArm(whoop5Detected: model.whoop5Detected),
                                              minutes: behavior.smartAlarmMinutes,
                                              weekdays: behavior.smartAlarmWeekdays,
                                              overrides: WindDownNudge.perDayWakeOverrides,
                                              from: tick.date) {
                let phrase = NextStrapAlarm.shortLabel(for: fire, now: tick.date)
                ViewThatFits(in: .horizontal) {
                    line(phrase, font: StrandFont.caption)
                    line(phrase, font: StrandFont.footnote)
                    line(NextStrapAlarm.Style.app.format(fire), font: StrandFont.footnote)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Next alarm \(phrase)"))
            }
        }
    }

    private func line(_ text: String, font: Font) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "alarm.fill")
                .imageScale(.small)
            Text(text)
        }
        .font(font.weight(.light))
        .foregroundStyle(StrandPalette.textSecondary)
        .lineLimit(1)
        .fixedSize()
    }
}
