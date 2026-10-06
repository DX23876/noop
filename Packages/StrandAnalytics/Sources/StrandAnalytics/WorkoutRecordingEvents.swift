import Foundation

/// Original event timestamps for Health export. Never infer events from edited or legacy summary rows.
public enum WorkoutRecordingEvents {
    public struct Event: Equatable, Sendable {
        public enum Kind: Sendable { case pause, resume, lap, segment }
        public let kind: Kind
        public let start: Double
        public let end: Double
    }

    public static func wallTime(activeSeconds: Double, start: Double, pauses: [WorkoutRecordingTimeline.Pause]) -> Double {
        var wall = start + activeSeconds
        var elapsedPause = 0.0
        for pause in pauses {
            guard let end = pause.endUnixSeconds else { continue }
            let activeAtPause = pause.startUnixSeconds - start - elapsedPause
            if activeSeconds > activeAtPause { wall += end - pause.startUnixSeconds }
            elapsedPause += end - pause.startUnixSeconds
        }
        return wall
    }

    public static func make(timeline: WorkoutRecordingTimeline, fallbackStart: Double,
                            end: Double, activeSeconds: Double) -> [Event] {
        guard timeline.isValid, fallbackStart.isFinite, end.isFinite, end > fallbackStart,
              activeSeconds.isFinite, activeSeconds >= 0 else { return [] }
        let start = timeline.startUnixSeconds ?? fallbackStart
        let pauses = timeline.pauses ?? []
        var events: [Event] = []
        for pause in pauses {
            guard let resume = pause.endUnixSeconds else { continue }
            events.append(Event(kind: .pause, start: pause.startUnixSeconds, end: pause.startUnixSeconds))
            // Closing a final pause at capture end is not a user resume. Health derives active
            // duration from the open pause just as it does from earlier pause/resume pairs.
            if resume < end { events.append(Event(kind: .resume, start: resume, end: resume)) }
        }
        for lap in timeline.manualSections(at: activeSeconds) {
            events.append(Event(kind: .lap,
                start: wallTime(activeSeconds: lap.startSeconds, start: start, pauses: pauses),
                end: wallTime(activeSeconds: lap.endSeconds, start: start, pauses: pauses)))
        }
        if let guidance = timeline.guidance {
            var begin = 0.0
            for transition in guidance.transitions {
                events.append(Event(kind: .segment,
                    start: wallTime(activeSeconds: begin, start: start, pauses: pauses),
                    end: wallTime(activeSeconds: transition.activeSeconds, start: start, pauses: pauses)))
                begin = transition.activeSeconds
            }
            if !guidance.isComplete, activeSeconds > begin {
                events.append(Event(kind: .segment,
                    start: wallTime(activeSeconds: begin, start: start, pauses: pauses), end: end))
            }
        }
        return events.filter { $0.start >= fallbackStart && $0.end <= end && $0.end >= $0.start }
            .sorted { $0.start < $1.start }
    }
}
