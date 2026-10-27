import Foundation

struct GoalMeasurement: Equatable {
    let value: Double
    let date: Date?
    /// True while the value rests on too little data to judge a goal on — a smoothed trend that is
    /// still cold-starting. The number is worth SHOWING (it is the best estimate available) but must
    /// not produce an "at risk" verdict, which is why this travels with the measurement rather than
    /// being re-derived by each consumer.
    var isProvisional: Bool = false
}
