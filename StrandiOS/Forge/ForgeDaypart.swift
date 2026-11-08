#if os(iOS)
import Foundation

/// Which part of the day Today is answering for. The page keeps the wearer's widgets; only the short
/// "right now" section under the hint follows the clock: the plan in the morning, the live Effort in the
/// day, the night ahead in the evening.
enum ForgeDaypart: String {
    case morning, day, evening

    /// Evening from two hours before the planned bedtime (never before 19:00, as the evening report), and
    /// through the small hours; morning from 04:00 until noon; day in between.
    static func current(now: Date = Date(), bedtime: Date?, calendar: Calendar = .current) -> ForgeDaypart {
        #if DEBUG
        // `--demo-daypart morning|day|evening` pins the part for captures.
        if let i = CommandLine.arguments.firstIndex(of: "--demo-daypart"), i + 1 < CommandLine.arguments.count,
           let pinned = ForgeDaypart(rawValue: CommandLine.arguments[i + 1]) {
            return pinned
        }
        #endif
        let hour = calendar.component(.hour, from: now)
        if hour < 4 { return .evening }
        if now >= ForgeToday.eveningStart(now: now, bedtime: bedtime, calendar: calendar) { return .evening }
        return hour < 12 ? .morning : .day
    }
}
#endif
