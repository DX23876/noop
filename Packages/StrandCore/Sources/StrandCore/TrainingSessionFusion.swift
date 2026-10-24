import Foundation
import WhoopStore
import StrandAnalytics

// Moved from the app (Android plan B3 step 4): the pure fusion of one session seen through several sources. The
// app's `Repository` reads the rows and persists the links (`Strand/Data/TrainingSessionFusion.swift`).

public struct TrainingSessionComponent: Identifiable, Equatable, Sendable {
    public let id: String
    public let row: WorkoutRow
    public let metadata: WorkoutSourceMetadataRow?

    public init(id: String, row: WorkoutRow, metadata: WorkoutSourceMetadataRow?) {
        self.id = id; self.row = row; self.metadata = metadata
    }

    public var kind: TrainingActivityKind {
        TrainingActivityClassifier.kind(forStoredName: row.sport)
    }
}

public struct UnifiedTrainingSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: TrainingActivityKind
    public let row: WorkoutRow
    public let components: [TrainingSessionComponent]
    public let fusionOrigin: String

    public init(id: String, kind: TrainingActivityKind, row: WorkoutRow, components: [TrainingSessionComponent],
                fusionOrigin: String) {
        self.id = id; self.kind = kind; self.row = row; self.components = components
        self.fusionOrigin = fusionOrigin
    }
}

public struct TrainingSessionFusionResult: Sendable {
    public let sessions: [UnifiedTrainingSession]
    public let ambiguous: [[TrainingSessionComponent]]
    public let generatedLinks: [TrainingSessionLinkRow]

    public init(sessions: [UnifiedTrainingSession], ambiguous: [[TrainingSessionComponent]],
                generatedLinks: [TrainingSessionLinkRow]) {
        self.sessions = sessions; self.ambiguous = ambiguous; self.generatedLinks = generatedLinks
    }
}

/// Pure, deterministic component fusion. It composes fields instead of choosing one source row and
/// throwing the other away, so Hevy's sets and HealthKit's route/HR can describe the same session.
public enum TrainingSessionResolver {
    public static func resolve(rows: [WorkoutRow], metadata: [WorkoutSourceMetadataRow],
                        links: [TrainingSessionLinkRow], decisions: [TrainingSessionPairDecisionRow] = [],
                        preferences: [TrainingSessionPreferenceRow],
                        nowTs: Int = Int(Date().timeIntervalSince1970)) -> TrainingSessionFusionResult {
        let metadataByNatural = Dictionary(grouping: metadata) { "\($0.source)|\($0.startTs)|\(WorkoutSource.sportKey($0.sport))" }
        let linkByKey = Dictionary(uniqueKeysWithValues: links.map { ($0.componentKey, $0) })
        let preferenceBySession = Dictionary(uniqueKeysWithValues: preferences.map { ($0.sessionId, $0) })
        let decisionByPair = Dictionary(uniqueKeysWithValues: decisions.map { (pairKey($0.leftKey, $0.rightKey), $0.decision) })
        let components = rows.map { row -> TrainingSessionComponent in
            let natural = "\(row.source)|\(row.startTs)|\(WorkoutSource.sportKey(row.sport))"
            let meta = metadataByNatural[natural]?.first
            let key = meta?.componentKey ?? natural
            return TrainingSessionComponent(id: key, row: row, metadata: meta)
        }
        var parent = Array(components.indices)
        func root(_ value: Int) -> Int {
            var x = value
            while parent[x] != x { x = parent[x] }
            return x
        }
        func join(_ a: Int, _ b: Int) {
            let ra = root(a), rb = root(b)
            if ra != rb { parent[rb] = ra }
        }

        let byPersistedSession = Dictionary(grouping: components.indices) { linkByKey[components[$0].id]?.sessionId }
        for (session, indices) in byPersistedSession where session != nil {
            guard let first = indices.first else { continue }
            for index in indices.dropFirst() { join(first, index) }
        }

        // Candidate pairing by a time-ordered sweep rather than every pair: a component can only pair
        // with one that STARTS within `candidateStartWindow`, so the walk stops as soon as the sorted
        // neighbour is out of reach. All-pairs was quadratic in the window's row count, which the Cardio
        // screen's "All" range (4000 days) and the workout detail both hand thousands of rows.
        var candidateSets: [Int: [Int]] = [:]
        let byStart = components.indices.sorted { components[$0].row.startTs < components[$1].row.startTs }
        for (position, i) in byStart.enumerated() {
            for other in byStart[(position + 1)...] {
                guard components[other].row.startTs - components[i].row.startTs <= candidateStartWindow else { break }
                let (a, b) = (min(i, other), max(i, other))
                guard WorkoutSource.classify(components[a].row.source) != WorkoutSource.classify(components[b].row.source),
                      compatible(components[a].kind, components[b].kind) else { continue }
                let decision = decisionByPair[pairKey(components[a].id, components[b].id)]
                if decision == "separate" { continue }
                if decision == "merge" { join(a, b); continue }
                if overlapShare(components[a].row, components[b].row) > 0.5 {
                    candidateSets[a, default: []].append(b)
                    candidateSets[b, default: []].append(a)
                }
            }
        }
        var ambiguous: [[TrainingSessionComponent]] = []
        for i in components.indices {
            guard let candidates = candidateSets[i], !candidates.isEmpty else { continue }
            let high = candidates.filter { isHighConfidence(components[i].row, components[$0].row) }
            // Auto-link only a MUTUALLY unambiguous pair: each side's single high-confidence partner is
            // the other. Anything else — one row overlapping two candidates, or a partner that also
            // matches a third row — is the wearer's call, so it stays separate and is reported once,
            // by its lowest-indexed member, rather than once per member.
            let mutual = high.count == 1
                && (candidateSets[high[0]]?.filter { isHighConfidence(components[high[0]].row, components[$0].row) }.count ?? 0) == 1
            if mutual {
                join(i, high[0])
            } else if candidates.allSatisfy({ $0 > i }) {
                ambiguous.append(([i] + candidates.sorted()).map { components[$0] })
            }
        }

        let groups = Dictionary(grouping: components.indices, by: root)
        var generated: [TrainingSessionLinkRow] = []
        let sessions = groups.values.map { indices -> UnifiedTrainingSession in
            let members = indices.map { components[$0] }
            let persistedId = members.compactMap { linkByKey[$0.id]?.sessionId }.sorted().first
            let sessionId = persistedId ?? "session|\(members.map(\.id).sorted().first ?? UUID().uuidString)"
            if members.count > 1 {
                generated += members.filter { linkByKey[$0.id] == nil }.map {
                    TrainingSessionLinkRow(componentKey: $0.id, sessionId: sessionId,
                                           origin: "automatic", updatedAtTs: nowTs)
                }
            }
            let preferredKind = preferenceBySession[sessionId]?.activityKind.flatMap(TrainingActivityKind.init(rawValue:))
            let preferredPrimary = preferenceBySession[sessionId]?.primaryComponentKey
                .flatMap { key in members.first { $0.id == key } }
            let primary = preferredPrimary ?? primaryComponent(in: members)
            return UnifiedTrainingSession(id: sessionId, kind: preferredKind ?? primary.kind,
                                          row: mergedRow(primary: primary, components: members),
                                          components: members.sorted { $0.row.startTs < $1.row.startTs },
                                          fusionOrigin: persistedId == nil ? "automatic" : "persisted")
        }.sorted { $0.row.startTs > $1.row.startTs }
        return .init(sessions: sessions, ambiguous: ambiguous, generatedLinks: generated)
    }

    /// How far two components' starts may sit apart and still describe one session. Wide enough for the
    /// drift between a phone, a watch and a strap that were started by hand; far short of a second bout.
    public static let candidateStartWindow = 600
    /// A pair NOOP may link without asking: near-identical windows, started within five minutes.
    private static let confidentStartWindow = 300
    private static let confidentOverlap = 0.8

    private static func isHighConfidence(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
        overlapShare(a, b) > confidentOverlap && abs(a.startTs - b.startTs) <= confidentStartWindow
    }

    private static func compatible(_ a: TrainingActivityKind, _ b: TrainingActivityKind) -> Bool {
        a == b || a == .other || b == .other
    }

    private static func pairKey(_ a: String, _ b: String) -> String { min(a, b) + "\u{1f}" + max(a, b) }

    private static func overlapShare(_ a: WorkoutRow, _ b: WorkoutRow) -> Double {
        let overlap = max(0, min(a.endTs, b.endTs) - max(a.startTs, b.startTs))
        let shorter = max(1, min(a.endTs - a.startTs, b.endTs - b.startTs))
        return Double(overlap) / Double(shorter)
    }

    private static func primaryComponent(in members: [TrainingSessionComponent]) -> TrainingSessionComponent {
        members.max { lhs, rhs in
            func score(_ component: TrainingSessionComponent) -> Int {
                var value = WorkoutSource.richness(component.row)
                let source = WorkoutSource.classify(component.row.source)
                if component.kind == .strength && (source == .hevy || source == .lifting) { value += 20 }
                if component.row.distanceM != nil { value += 3 }
                if component.metadata?.activitiesJSON != nil { value += 2 }
                return value
            }
            return score(lhs) < score(rhs)
        } ?? members[0]
    }

    private static func mergedRow(primary: TrainingSessionComponent,
                                  components: [TrainingSessionComponent]) -> WorkoutRow {
        func first<T>(_ key: KeyPath<WorkoutRow, T?>) -> T? {
            primary.row[keyPath: key] ?? components.compactMap { $0.row[keyPath: key] }.first
        }
        return WorkoutRow(startTs: primary.row.startTs, endTs: primary.row.endTs,
                          sport: primary.row.sport, source: primary.row.source,
                          durationS: first(\.durationS), energyKcal: first(\.energyKcal),
                          avgHr: first(\.avgHr), maxHr: first(\.maxHr), strain: first(\.strain),
                          distanceM: first(\.distanceM), zonesJSON: first(\.zonesJSON),
                          notes: first(\.notes), steps: first(\.steps))
    }
}

extension TrainingSessionResolver {
    /// The canonical sessions of `[lo, hi]`: every source's workout rows through the union reader, fused with
    /// the stored metadata, links, pair decisions and preferences. Links the fusion generates are written
    /// back, so the next read finds them.
    public static func read(reader: StoreReader, from lo: Int, to hi: Int,
                            dismissedDetectedSpans: [String]) async -> TrainingSessionFusionResult {
        let rows = await reader.rawWorkoutRows(from: lo, to: hi, dismissedDetectedSpans: dismissedDetectedSpans)
        let store = reader.store
        let now = Int(Date().timeIntervalSince1970)
        let metadata = (try? await store.workoutSourceMetadata(from: lo, to: hi)) ?? []
        let links = (try? await store.trainingSessionLinks()) ?? []
        let decisions = (try? await store.trainingSessionPairDecisions()) ?? []
        let preferences = (try? await store.trainingSessionPreferences()) ?? []
        let result = resolve(rows: rows, metadata: metadata, links: links, decisions: decisions,
                             preferences: preferences, nowTs: now)
        if !result.generatedLinks.isEmpty { try? await store.upsertTrainingSessionLinks(result.generatedLinks) }
        return result
    }
}
