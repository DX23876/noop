import Foundation

/// Prospective recording evidence, independent of scoring and platform location services.
/// All times are active workout seconds supplied by the caller; pauses never lengthen a section.
public struct WorkoutRecordingTimeline: Codable, Equatable, Sendable {
    public struct Pause: Codable, Equatable, Sendable {
        public let startUnixSeconds: Double
        public var endUnixSeconds: Double?
    }
    public struct Reading: Codable, Equatable, Sendable {
        public let seconds: Double
        public let bpm: Int
        public let zone: Int
    }

    public struct Position: Codable, Equatable, Sendable {
        public let seconds: Double
        public let distanceM: Double
        public let segment: Int
    }

    public struct Section: Codable, Equatable, Sendable, Identifiable {
        public let index: Int
        public let startSeconds: Double
        public let endSeconds: Double
        public let distanceM: Double?
        public let interrupted: Bool
        public let partial: Bool
        /// Barometric height climbed and descended inside the section; nil when nothing measured height.
        public var ascentM: Double? = nil
        public var descentM: Double? = nil
        public var id: Int { index }
        public var duration: Double { max(0, endSeconds - startSeconds) }
        public var speedMps: Double? {
            guard !interrupted, let distanceM, distanceM > 0, duration > 0 else { return nil }
            return distanceM / duration
        }
    }

    public let splitLengthM: Double?
    public let zoneUpperBPM: [Double]
    public let zoneLowerBPM: [Double]?
    public private(set) var readings: [Reading] = []
    public private(set) var splits: [Section] = []
    public private(set) var laps: [Section] = []
    public private(set) var distanceM = 0.0
    public private(set) var recentPositions: [Position] = []
    public private(set) var pauses: [Pause]? = nil
    public var guidance: WorkoutGuidance? = nil
    public var pacer: WorkoutPacer? = nil
    public var startUnixSeconds: Double? = nil
    public var endUnixSeconds: Double? = nil
    public private(set) var hasRouteGap: Bool? = nil
    /// Barometric elevation gain and loss over the active workout (`BarometricElevationCounter`); nil when
    /// no barometer reported, so a missing measurement never reads as a flat route.
    public private(set) var ascentM: Double? = nil
    public private(set) var descentM: Double? = nil
    // Optional so a payload written before elevation existed still decodes.
    private var splitElevationStart: ElevationMark? = nil
    private var lapElevationStart: ElevationMark? = nil
    private var splitStart = 0.0
    private var splitInterrupted = false
    private var lapStart = 0.0
    private var lapDistance = 0.0
    private var lapInterrupted = false

    /// Reject malformed restored evidence before a UI turns durations into integer readouts.
    public var isValid: Bool {
        func time(_ value: Double) -> Bool { value.isFinite && value >= 0 && value < Double(Int.max) / 1000 }
        func section(_ value: Section) -> Bool {
            value.index > 0 && time(value.startSeconds) && time(value.endSeconds)
                && value.endSeconds >= value.startSeconds
                && (value.distanceM.map { $0.isFinite && $0 >= 0 } ?? true)
        }
        return distanceM.isFinite && distanceM >= 0
            && (startUnixSeconds.map { $0.isFinite && $0 > 0 } ?? true)
            && (endUnixSeconds.map { $0.isFinite && $0 >= (startUnixSeconds ?? 0) } ?? true)
            && (guidance?.isValid ?? true)
            && (pacer?.isValid ?? true)
            && (splitLengthM.map { $0.isFinite && $0 >= 1 } ?? true)
            && (zoneUpperBPM.isEmpty || (zoneUpperBPM.count == 5 && zoneUpperBPM.allSatisfy(\.isFinite)))
            && (zoneLowerBPM.map { $0.count == 5 && $0.allSatisfy(\.isFinite) } ?? true)
            && readings.allSatisfy { time($0.seconds) && (1...300).contains($0.bpm) && (0...5).contains($0.zone) }
            && recentPositions.allSatisfy { time($0.seconds) && $0.distanceM.isFinite && $0.distanceM >= 0 && $0.segment >= 0 }
            && splits.allSatisfy(section) && laps.allSatisfy(section)
            && time(splitStart) && time(lapStart) && lapDistance.isFinite && lapDistance >= 0
            && [ascentM, descentM].allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? true }
            && (splits + laps).allSatisfy { [$0.ascentM, $0.descentM].allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? true } }
            && (pauses?.enumerated().allSatisfy { index, pause in
                pause.startUnixSeconds.isFinite && pause.startUnixSeconds > 0
                    && (pause.endUnixSeconds.map { $0.isFinite && $0 >= pause.startUnixSeconds } ?? (index == (pauses?.count ?? 0) - 1))
                    && (index == 0 || pause.startUnixSeconds >= (pauses?[index - 1].endUnixSeconds ?? .infinity))
            } ?? true)
    }

    public init(splitLengthM: Double? = nil, zoneUpperBPM: [Double] = [], zoneLowerBPM: [Double]? = nil) {
        self.splitLengthM = splitLengthM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.zoneUpperBPM = zoneUpperBPM.count == 5 && zoneUpperBPM.allSatisfy(\.isFinite)
            && zip(zoneUpperBPM, zoneUpperBPM.dropFirst()).allSatisfy({ $0 < $1 }) ? zoneUpperBPM : []
        self.zoneLowerBPM = zoneLowerBPM.flatMap {
            $0.count == 5 && $0.allSatisfy(\.isFinite) ? $0 : nil
        }
    }

    public mutating func recordHeartRate(_ bpm: Int, at seconds: Double) {
        guard seconds.isFinite, seconds >= 0, (1...300).contains(bpm),
              readings.last.map({ seconds > $0.seconds }) ?? true else { return }
        let below = zoneLowerBPM?.first.map { Double(bpm) < $0 - 1e-9 } ?? false
        let zone = below ? 0 : zoneUpperBPM.firstIndex(where: { Double(bpm) < $0 - 1e-9 }).map { $0 + 1 } ?? 5
        readings.append(Reading(seconds: seconds, bpm: bpm, zone: zone))
    }

    /// A segment boundary means unknown movement, never a straight-line replacement for missing GPS.
    public mutating func interrupt() {
        hasRouteGap = true
        splitInterrupted = true
        lapInterrupted = true
        recentPositions.removeAll(keepingCapacity: true)
    }

    /// A deliberate pause resets current pace, without turning the measured section into a GPS gap.
    public mutating func pause() {
        recentPositions.removeAll(keepingCapacity: true)
    }

    public mutating func beginPause(atUnixSeconds seconds: Double) {
        guard seconds.isFinite, seconds > 0, pauses?.last?.endUnixSeconds != nil || pauses?.isEmpty != false else { return }
        if pauses == nil { pauses = [] }
        pauses?.append(Pause(startUnixSeconds: seconds, endUnixSeconds: nil))
        pause()
    }

    public mutating func endPause(atUnixSeconds seconds: Double) {
        guard seconds.isFinite, let last = pauses?.last, last.endUnixSeconds == nil,
              seconds >= last.startUnixSeconds, let index = pauses?.indices.last else { return }
        pauses?[index].endUnixSeconds = seconds
    }

    public mutating func recordDistance(_ meters: Double, at seconds: Double, segment: Int) {
        guard meters.isFinite, meters >= distanceM, seconds.isFinite, seconds >= 0,
              recentPositions.last.map({ seconds > $0.seconds }) ?? true else { return }
        let previous = recentPositions.last
        if let previous, previous.segment != segment {
            interrupt()
        }
        let continuous = previous?.segment == segment
        if let length = splitLengthM, let previous, continuous, meters > previous.distanceM {
            var boundary = Double(splits.count + 1) * length
            // Crossing times are interpolated only inside one valid measured leg, never across a gap.
            while boundary <= meters {
                let fraction = (boundary - previous.distanceM) / (meters - previous.distanceM)
                let time = previous.seconds + fraction * (seconds - previous.seconds)
                let climb = elevation(since: splitElevationStart)
                splits.append(Section(index: splits.count + 1, startSeconds: splitStart,
                                      endSeconds: time, distanceM: length,
                                      interrupted: splitInterrupted, partial: false,
                                      ascentM: climb?.ascentM, descentM: climb?.descentM))
                splitElevationStart = currentElevationMark
                splitStart = time
                splitInterrupted = false
                boundary += length
            }
        }
        distanceM = meters
        recentPositions.append(Position(seconds: seconds, distanceM: meters, segment: segment))
        // One point before the window remains available for boundary interpolation.
        while recentPositions.count > 2, recentPositions[1].seconds < seconds - 30 {
            recentPositions.removeFirst()
        }
    }

    /// One supplied clock for every pace/speed readout. Five seconds of fresh movement are required.
    public func currentSpeedMps(at seconds: Double, lastFixAge: Double) -> Double? {
        guard seconds.isFinite, lastFixAge >= 0, lastFixAge <= 5,
              let first = recentPositions.first, let last = recentPositions.last,
              first.segment == last.segment, last.seconds <= seconds,
              seconds - last.seconds <= 5, last.seconds - first.seconds >= 5 else { return nil }
        let windowStart = max(first.seconds, last.seconds - 30)
        var startDistance = first.distanceM
        for (a, b) in zip(recentPositions, recentPositions.dropFirst()) where a.seconds <= windowStart && b.seconds >= windowStart {
            let fraction = (windowStart - a.seconds) / (b.seconds - a.seconds)
            startDistance = a.distanceM + fraction * (b.distanceM - a.distanceM)
        }
        let elapsed = last.seconds - windowStart
        let meters = last.distanceM - startDistance
        guard elapsed > 0, meters > 0 else { return nil }
        return meters / elapsed
    }

    @discardableResult
    public mutating func markLap(at seconds: Double) -> Bool {
        guard seconds.isFinite, seconds > lapStart else { return false }
        let climb = elevation(since: lapElevationStart)
        laps.append(Section(index: laps.count + 1, startSeconds: lapStart, endSeconds: seconds,
                            distanceM: splitLengthM == nil ? nil : max(0, distanceM - lapDistance),
                            interrupted: lapInterrupted, partial: false,
                            ascentM: climb?.ascentM, descentM: climb?.descentM))
        lapElevationStart = currentElevationMark
        lapStart = seconds
        lapDistance = distanceM
        lapInterrupted = false
        return true
    }

    public func sections(at seconds: Double) -> [Section] {
        guard let length = splitLengthM else { return [] }
        let remainder = max(0, distanceM - Double(splits.count) * length)
        guard remainder > 0, seconds > splitStart else { return splits }
        let climb = elevation(since: splitElevationStart)
        return splits + [Section(index: splits.count + 1, startSeconds: splitStart, endSeconds: seconds,
                                 distanceM: remainder, interrupted: splitInterrupted, partial: true,
                                 ascentM: climb?.ascentM, descentM: climb?.descentM)]
    }

    public func manualSections(at seconds: Double) -> [Section] {
        guard !laps.isEmpty, seconds > lapStart else { return laps }
        let climb = elevation(since: lapElevationStart)
        return laps + [Section(index: laps.count + 1, startSeconds: lapStart, endSeconds: seconds,
                               distanceM: splitLengthM == nil ? nil : max(0, distanceM - lapDistance),
                               interrupted: lapInterrupted, partial: true,
                               ascentM: climb?.ascentM, descentM: climb?.descentM)]
    }

    /// Adds the height one barometer reading counted. A zero reading still marks elevation as measured,
    /// so a flat workout shows 0 m rather than no measurement.
    public mutating func recordElevation(gainM: Double, lossM: Double) {
        guard gainM.isFinite, gainM >= 0, lossM.isFinite, lossM >= 0 else { return }
        ascentM = (ascentM ?? 0) + gainM
        descentM = (descentM ?? 0) + lossM
    }

    /// Cumulative gain and loss at a section boundary.
    private struct ElevationMark: Codable, Equatable, Sendable {
        let ascentM: Double
        let descentM: Double
    }

    private var currentElevationMark: ElevationMark? {
        guard let ascentM, let descentM else { return nil }
        return ElevationMark(ascentM: ascentM, descentM: descentM)
    }

    /// Height counted since a boundary. A boundary set before the first reading counts from zero.
    private func elevation(since mark: ElevationMark?) -> ElevationMark? {
        guard let ascentM, let descentM else { return nil }
        return ElevationMark(ascentM: max(0, ascentM - (mark?.ascentM ?? 0)),
                             descentM: max(0, descentM - (mark?.descentM ?? 0)))
    }

    public func averageBpm(in section: Section) -> Int? {
        let samples = readings.filter { $0.seconds >= section.startSeconds && $0.seconds < section.endSeconds }
        guard !samples.isEmpty else { return nil }
        return Int((Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)).rounded())
    }

    /// Continuous current-zone streak, bounded by freshness rather than silently counting a dropout.
    public func currentZoneSeconds(at seconds: Double) -> Double {
        guard let last = readings.last, last.zone > 0, seconds >= last.seconds, seconds - last.seconds <= 5 else { return 0 }
        var first = last
        for reading in readings.dropLast().reversed() {
            guard reading.zone == last.zone, first.seconds - reading.seconds <= 10 else { break }
            first = reading
        }
        return seconds - first.seconds
    }

    /// Credit at most ten seconds after a received reading; a dropout is not time in an invented zone.
    public func zoneSeconds(at seconds: Double) -> [Double] {
        guard zoneUpperBPM.count == 5 else { return [] }
        var totals = Array(repeating: 0.0, count: 5)
        for index in readings.indices {
            let sample = readings[index]
            let end = index + 1 < readings.count ? readings[index + 1].seconds : seconds
            let duration = max(0, min(10, min(seconds, end) - sample.seconds))
            if (1...5).contains(sample.zone) { totals[sample.zone - 1] += duration }
        }
        return totals
    }
}
