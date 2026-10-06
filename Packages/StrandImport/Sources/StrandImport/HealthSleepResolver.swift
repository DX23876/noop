import Foundation

/// Resolves one writer per contiguous night, retaining detailed stages without overlapping minutes.
/// Framework-free so source priority, midnight, gaps and duplicate exports can be regression-tested.
public enum HealthSleepResolver {
    public enum Stage: Int, Sendable { case unspecified, core, deep, rem, awake, inBed }
    public struct Sample: Sendable {
        public let start: Date
        public let end: Date
        public let source: String
        public let isWatch: Bool
        public let stage: Stage
        public init(start: Date, end: Date, source: String, isWatch: Bool, stage: Stage) {
            self.start = start; self.end = end; self.source = source; self.isWatch = isWatch; self.stage = stage
        }
    }
    public struct Night: Equatable, Sendable {
        public let wake: Date
        public let asleep: Double
        public let deep: Double
        public let rem: Double
        public let core: Double
    }

    private struct Candidate {
        let source: String
        let samples: [Sample]
        let start: Date
        let end: Date
        let isWatch: Bool
        let detailed: Bool
    }

    public static func resolve(_ input: [Sample]) -> [Night] {
        let valid = input.filter { $0.end > $0.start && $0.stage != .inBed }
        var candidates: [Candidate] = []
        // Group each writer separately. A low-priority all-day block must never bridge a Watch's
        // main night and afternoon nap into one artificial night.
        for (source, samples) in Dictionary(grouping: valid, by: \.source) {
            let asleep = samples.filter { $0.stage != .awake }.sorted { $0.start < $1.start }
            var groups: [[Sample]] = []
            var frontier: Date?
            for sample in asleep {
                if let end = frontier, sample.start.timeIntervalSince(end) <= 90 * 60 {
                    groups[groups.count - 1].append(sample)
                    frontier = max(end, sample.end)
                } else {
                    groups.append([sample]); frontier = sample.end
                }
            }
            for group in groups {
                guard let start = group.map(\.start).min(), let end = group.map(\.end).max() else { continue }
                let awake = samples.filter { $0.stage == .awake && $0.start < end && $0.end > start }
                candidates.append(.init(source: source, samples: group + awake, start: start, end: end,
                    isWatch: group.contains { $0.isWatch },
                    detailed: group.contains { [.deep, .rem, .core].contains($0.stage) }))
            }
        }
        candidates.sort {
            if $0.isWatch != $1.isWatch { return $0.isWatch }
            if $0.detailed != $1.detailed { return $0.detailed }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.start < $1.start
        }
        var chosen: [Candidate] = []
        for candidate in candidates {
            let overlaps = chosen.contains {
                candidate.start <= $0.end.addingTimeInterval(90 * 60) &&
                    candidate.end >= $0.start.addingTimeInterval(-90 * 60)
            }
            if !overlaps { chosen.append(candidate) }
        }
        return chosen.sorted { $0.start < $1.start }.compactMap { candidate in
            let selected = candidate.samples
            let boundaries = Set([candidate.start, candidate.end] + selected.flatMap {
                [max(candidate.start, $0.start), min(candidate.end, $0.end)]
            }).sorted()
            var deep = 0.0, rem = 0.0, core = 0.0
            var wake: Date?
            for (start, end) in zip(boundaries, boundaries.dropFirst()) {
                let covering = selected.filter { $0.start < end && $0.end > start }
                // Awake wins a conflict; specific stages supersede an encompassing unspecified block.
                guard let stage = covering.map(\.stage).max(by: { $0.rawValue < $1.rawValue }) else { continue }
                let minutes = end.timeIntervalSince(start) / 60
                switch stage {
                case .deep: deep += minutes; wake = end
                case .rem: rem += minutes; wake = end
                case .core, .unspecified: core += minutes; wake = end
                case .awake, .inBed: break
                }
            }
            guard let wake else { return nil }
            return Night(wake: wake, asleep: deep + rem + core, deep: deep, rem: rem, core: core)
        }
    }
}
