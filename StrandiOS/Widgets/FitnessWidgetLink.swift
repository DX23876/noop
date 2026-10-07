#if os(iOS)
import Foundation

/// Where a tap on a fitness widget lands. The extension only knows URLs; this turns them into the
/// screens the matching Today cards open, so a widget and its card always lead to the same place.
enum FitnessWidgetLink: Equatable {
    /// The Sleep tab (sleep widget).
    case sleep
    /// One detail pushed on Today's stack.
    case detail(TabRoute)

    /// `noop://sleep`, `noop://metric/<catalog key>`, `noop://weight`, `noop://workouts`,
    /// `noop://trainingLoad`, `noop://health`. Any other host is not a fitness widget's and returns nil.
    init?(url: URL) {
        switch url.host {
        case "sleep": self = .sleep
        case "metric":
            let key = url.lastPathComponent
            guard !key.isEmpty, key != "/" else { return nil }
            self = .detail(.metric(key))
        case "weight": self = .detail(.weight)
        case "workouts": self = .detail(.workouts)
        case "trainingLoad": self = .detail(.trainingLoad)
        case "health": self = .detail(.health)
        default: return nil
        }
    }
}
#endif
