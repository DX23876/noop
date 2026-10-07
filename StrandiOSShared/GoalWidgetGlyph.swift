import Foundation

extension GoalWidgetSnapshot {

    /// A goal's small shape, reduced by the app to what the widget draws, so the extension needs neither
    /// the analytics nor the goal readings. The same shapes as Today's goals card:
    /// - `track`: a sum or a count, filled to `fraction`, with the plan's mark at `paceFraction`;
    /// - `way`: a target value, the way from start to target filled to `fraction`, waypoints at `marks`;
    /// - `weeks`: consistency, the last finished weeks oldest first (`states`: achieved, almost, missed,
    ///   protected, noData);
    /// - `days`: a week of "days with …", one state per day (met, missed, today, todayMet, future, rest,
    ///   noData);
    /// - `columns`: an average, recent `values` against `target`;
    /// - `band`: a held value, the band from `bandLow` to `bandHigh` and the `latest` reading, all 0…1
    ///   along the track.
    ///
    /// `kind` and the states are plain strings, so a payload from a newer app still decodes in an older
    /// extension: an unknown kind draws nothing instead of emptying the whole widget.
    public struct Glyph: Codable, Equatable {
        public var kind: String
        public var fraction: Double?
        public var paceFraction: Double?
        public var marks: [Double]?
        public var states: [String]?
        public var values: [Double?]?
        public var target: Double?
        public var higherIsBetter: Bool?
        public var bandLow: Double?
        public var bandHigh: Double?
        public var latest: Double?

        public init(kind: String, fraction: Double? = nil, paceFraction: Double? = nil, marks: [Double]? = nil,
                    states: [String]? = nil, values: [Double?]? = nil, target: Double? = nil,
                    higherIsBetter: Bool? = nil, bandLow: Double? = nil, bandHigh: Double? = nil,
                    latest: Double? = nil) {
            self.kind = kind
            self.fraction = fraction
            self.paceFraction = paceFraction
            self.marks = marks
            self.states = states
            self.values = values
            self.target = target
            self.higherIsBetter = higherIsBetter
            self.bandLow = bandLow
            self.bandHigh = bandHigh
            self.latest = latest
        }
    }
}
