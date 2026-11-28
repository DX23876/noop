import Foundation

public extension Calendar {
    /// This calendar's time zone, week start and locale on the Gregorian calendar, which every stored
    /// `yyyy-MM-dd` key is written in (`StoreReader.localDayKey`, en_US_POSIX).
    ///
    /// A key built from, or read through, the device's own calendar is wrong wherever that calendar is not
    /// Gregorian: a Thai iPhone defaults to the Buddhist calendar, where today's components read 2569-11-28 and
    /// the key "2026-11-28" names a day in 1483. Every helper that turns a date into a day key or back takes
    /// its calendar through this, so the time zone still follows the wearer while the numbering never does.
    var gregorianForDayKeys: Calendar {
        if identifier == .gregorian { return self }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        gregorian.locale = locale
        gregorian.firstWeekday = firstWeekday
        gregorian.minimumDaysInFirstWeek = minimumDaysInFirstWeek
        return gregorian
    }
}
