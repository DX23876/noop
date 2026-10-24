import Foundation
import WhoopStore
import StrandAnalytics
import StrandCore

extension Repository {
    func trainingSessions(days: Int = 4000) async -> TrainingSessionFusionResult {
        let now = Int(Date().timeIntervalSince1970)
        return await trainingSessions(from: now - days * 86_400, to: now + 86_400)
    }

    /// The canonical session one component start belongs to, fused over the day around it.
    ///
    /// A workout detail only needs to know which session it is part of, and fusing the whole library to
    /// answer that made opening one workout cost a full-history pass. A day either side comfortably
    /// covers every candidate, because a pair must start within `candidateStartWindow` to be one.
    func canonicalTrainingSession(containingStartTs startTs: Int) async -> UnifiedTrainingSession? {
        let result = await trainingSessions(from: startTs - 86_400, to: startTs + 86_400)
        return result.sessions.first {
            $0.row.startTs == startTs || $0.components.contains { $0.row.startTs == startTs }
        }
    }

    func trainingSessions(from lo: Int, to hi: Int) async -> TrainingSessionFusionResult {
        guard let store = await storeHandle() else {
            return TrainingSessionResolver.resolve(rows: [], metadata: [], links: [], preferences: [])
        }
        return await TrainingSessionResolver.read(reader: storeReader(store), from: lo, to: hi,
                                                  dismissedDetectedSpans: dismissedDetectedWorkoutSpans)
    }

    func decideTrainingSessionPair(_ components: [TrainingSessionComponent], merge: Bool) async {
        guard components.count >= 2, let store = await storeHandle() else { return }
        let now = Int(Date().timeIntervalSince1970)
        let sorted = components.sorted { $0.id < $1.id }
        for index in 1..<sorted.count {
            try? await store.upsertTrainingSessionPairDecision(.init(
                leftKey: sorted[0].id, rightKey: sorted[index].id,
                decision: merge ? "merge" : "separate", updatedAtTs: now))
        }
        if merge {
            let sessionId = "session|\(sorted[0].id)"
            try? await store.upsertTrainingSessionLinks(sorted.map {
                .init(componentKey: $0.id, sessionId: sessionId, origin: "user", updatedAtTs: now)
            })
        }
    }
}
