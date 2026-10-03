import XCTest
import WhoopStore
@testable import Strand

/// Regression tests for the Coach review of 2 October 2026 (`artifacts/qa/coach-review-2026-10-02.md`).
/// Each test reproduces one confirmed finding through the real store/engine type it lives in.
@MainActor
final class CoachReviewFixesTests: XCTestCase {

    // MARK: - Tool arguments (finding 4)

    func testOversizedNumericToolArgumentIsRejectedInsteadOfTrapping() throws {
        let json = try JSONSerialization.jsonObject(with: Data(#"{"days":1e100,"limit":-1e300}"#.utf8))
        let input = try XCTUnwrap(json as? [String: Any])
        XCTAssertNil(AICoachEngine.intArg(input["days"]))
        XCTAssertNil(AICoachEngine.intArg(input["limit"]))
        XCTAssertNil(AICoachEngine.intArg(Double.nan))
        XCTAssertNil(AICoachEngine.intArg(Double.infinity))
    }

    func testOrdinaryNumericToolArgumentsStillParse() throws {
        let json = try JSONSerialization.jsonObject(with: Data(#"{"a":30,"b":7.9,"c":-3,"d":" 12 "}"#.utf8))
        let input = try XCTUnwrap(json as? [String: Any])
        XCTAssertEqual(AICoachEngine.intArg(input["a"]), 30)
        XCTAssertEqual(AICoachEngine.intArg(input["b"]), 7)
        XCTAssertEqual(AICoachEngine.intArg(input["c"]), -3)
        XCTAssertEqual(AICoachEngine.intArg(input["d"]), 12)
        XCTAssertNil(AICoachEngine.intArg(input["missing"]))
    }

    // MARK: - Card analysis purposes (finding 1)

    func testCardContextNeedsEveryPurposeItDeclares() {
        let stress = CoachCardContext(title: "Stress", summary: "…",
                                      requiredPurposes: [.coreBiometrics, .stress])
        XCTAssertFalse(stress.isAllowed(by: ToolConsent(enabled: [.coreBiometrics, .workouts])))
        XCTAssertTrue(stress.isAllowed(by: ToolConsent(enabled: [.coreBiometrics, .stress])))
    }

    func testCardContextDefaultsToCoreBiometrics() {
        let card = CoachCardContext(title: "HRV", summary: "…")
        XCTAssertEqual(card.requiredPurposes, [.coreBiometrics])
        XCTAssertFalse(card.isAllowed(by: ToolConsent(enabled: [.workouts])))
    }

    func testDashboardAndExploreCardsDeclareWhatTheirSummaryCarries() {
        XCTAssertEqual(CoachCardContext.purposes(forDashboard: .stress), [.coreBiometrics, .stress])
        XCTAssertEqual(CoachCardContext.purposes(forDashboard: .sleep), [.coreBiometrics])
        XCTAssertEqual(CoachCardContext.purposes(forExplore: "my-whoop", windowDays: 30), [.coreBiometrics])
        XCTAssertEqual(CoachCardContext.purposes(forExplore: "my-whoop", windowDays: 180),
                       [.coreBiometrics, .longHistory])
        XCTAssertEqual(CoachCardContext.purposes(forExplore: "my-whoop", windowDays: nil),
                       [.coreBiometrics, .longHistory])
        XCTAssertEqual(CoachCardContext.purposes(forExplore: "noop-mood", windowDays: 7), [.logs])
    }

    func testBlockedCardIsConsumedWithoutSending() async {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-card-purpose-\(UUID().uuidString)"))
        // `toolConsent` persists to the test host's defaults, which later suites read.
        let previous = engine.toolConsent
        defer { engine.toolConsent = previous }
        engine.toolConsent = ToolConsent(enabled: [.coreBiometrics])
        engine.openedFromCard(CoachCardContext(title: "Stress", summary: "…",
                                               requiredPurposes: [.coreBiometrics, .stress]))
        await engine.runCardAnalysisIfNeeded()
        XCTAssertNil(engine.pendingCardContext)
        XCTAssertTrue(engine.messages.isEmpty)
    }

    // MARK: - Sensitive journal labels (finding 3)

    func testSensitiveJournalLabelsAreRecognisedInEverySupportedLanguage() {
        let sensitive = [
            "Sick today", "Krank heute", "Maladie", "Enfermedad", "Malattia", "Doença", "Choroba",
            "Болезнь", "生病", "性生活", "Sexo", "Relación", "Relazione", "Связь с партнёром",
            "Marihuana", "Cannabis", "单身", "單身"
        ]
        for label in sensitive {
            XCTAssertTrue(CoachSensitiveJournalPolicy.isSensitive(label: label), label)
        }
    }

    func testOrdinaryJournalLabelsStayOrdinary() {
        for label in ["Caffeine", "Alcohol", "Late meal", "Stretching", "Sesión de fuerza", "Больше воды"] {
            XCTAssertFalse(CoachSensitiveJournalPolicy.isSensitive(label: label), label)
        }
    }

    // MARK: - Plan completion uniqueness (finding 5)

    func testOneWorkoutCannotBeConfirmedForTwoCommitments() {
        let store = CoachPlanStore(loading: false)
        store.addUserSession(day: "2026-08-10", time: nil, sport: "Running", intent: .easy)
        store.addUserSession(day: "2026-08-10", time: nil, sport: "Running", intent: .easy)
        let first = store.proposals[0].id, second = store.proposals[1].id
        let start = 1_786_356_000
        let row = WorkoutRow(startTs: start, endTs: start + 3600, sport: "Running", source: "apple-health",
                             durationS: 3600, energyKcal: nil, avgHr: 140, maxHr: 170,
                             strain: 48, distanceM: 10_000, zonesJSON: nil, notes: nil, steps: nil)
        let workout = PlanWorkoutReference(row)
        store.setReconciliationResolutions([
            PlanReconciliationResolution(proposalId: first, kind: .candidates, candidates: [workout]),
            PlanReconciliationResolution(proposalId: second, kind: .candidates, candidates: [workout])
        ])

        store.confirmWorkout(workout, for: first)
        XCTAssertFalse(store.reconciliationResolutions.contains { $0.candidates.contains(workout) },
                       "a confirmed workout must leave every other plan's question")
        store.confirmWorkout(workout, for: second)

        XCTAssertEqual(store.proposals.first { $0.id == first }?.status, .completed)
        XCTAssertNotEqual(store.proposals.first { $0.id == second }?.status, .completed)
        XCTAssertEqual(store.proposals.filter { $0.completionEvidence?.workoutKey == workout.workoutKey }.count, 1)
    }

    func testChangingOnlyTheTimeKeepsTheSessionsDecisionHistory() {
        let store = CoachPlanStore(loading: false)
        store.addUserSession(day: "2026-08-10", time: nil, sport: "Running", intent: .easy)
        let id = store.proposals[0].id
        let before = store.proposals[0]
        let time = Date(timeIntervalSince1970: 1_786_356_000)
        store.setTime(id, at: time)
        let after = store.proposals[0]
        XCTAssertEqual(after.time, time)
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.source, before.source)
        XCTAssertNil(after.swappedFrom)
    }

    // MARK: - Paused goal edit (finding 6)

    private func goalStore() -> (CoachGoalStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "CoachReviewGoal-\(UUID().uuidString)")!
        return (CoachGoalStore(defaults: defaults), defaults)
    }

    func testEditingAPausedGoalKeepsItPaused() {
        let (store, _) = goalStore()
        store.commit(CoachGoal(kind: .run, title: "10k"))
        let id = store.goals[0].id
        store.pause(id, reason: .travel, on: Date(timeIntervalSince1970: 1_700_000_000))

        var draft = store.goals[0]
        draft.title = "10k in spring"
        store.commit(draft, editingId: id)
        XCTAssertEqual(store.goal(id: id)?.status, .paused)
        XCTAssertEqual(store.goal(id: id)?.title, "10k in spring")

        let resumedAt = Date(timeIntervalSince1970: 1_700_086_400)
        store.resume(id, on: resumedAt)
        XCTAssertEqual(store.goal(id: id)?.status, .active)
        XCTAssertEqual(store.goal(id: id)?.pauseIntervals.last?.endedAt, resumedAt)
    }

    func testActiveGoalWithAnOpenPauseIsRepairedToPausedOnLoad() throws {
        let (store, defaults) = goalStore()
        store.commit(CoachGoal(kind: .run, title: "10k"))
        let id = store.goals[0].id
        var broken = store.goals[0]
        broken.pauseIntervals = [.init(startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil,
                                       reason: .travel)]
        broken.status = .active
        defaults.set(try JSONEncoder().encode([broken]), forKey: CoachGoalStore.goalsKey)

        let reloaded = CoachGoalStore(defaults: defaults)
        XCTAssertEqual(reloaded.goal(id: id)?.status, .paused)
        XCTAssertNil(reloaded.goal(id: id)?.pauseIntervals.last?.endedAt)
    }

    // MARK: - Conversation switch during a reply (finding 7)

    func testLeavingAConversationStopsTheReplyInFlight() {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-switch-\(UUID().uuidString)"))
        engine.appendMessage(ChatMessage(role: .user, text: "first"))
        let original = engine.activeConversationID
        engine.sending = true
        engine.newConversation()
        XCTAssertFalse(engine.sending)
        XCTAssertNotEqual(engine.activeConversationID, original)

        engine.sending = true
        if let original { engine.switchTo(original) }
        XCTAssertFalse(engine.sending)
    }

    // MARK: - Custom streaming auth (finding 8)

    func testCustomStreamingUsesTheConfiguredAuthHeader() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: AIProvider.customAuthHeaderKey)
        defer {
            if let previous { defaults.set(previous, forKey: AIProvider.customAuthHeaderKey) }
            else { defaults.removeObject(forKey: AIProvider.customAuthHeaderKey) }
        }

        defaults.set(CustomAIAuthHeader.xAPIKey.rawValue, forKey: AIProvider.customAuthHeaderKey)
        var request = URLRequest(url: URL(string: "https://example.invalid/v1/chat/completions")!)
        CustomClient().authorizeStreamRequest(&request, key: "dummy")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "dummy")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        defaults.set(CustomAIAuthHeader.bearer.rawValue, forKey: AIProvider.customAuthHeaderKey)
        var bearer = URLRequest(url: URL(string: "https://example.invalid/v1/chat/completions")!)
        CustomClient().authorizeStreamRequest(&bearer, key: "dummy")
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Authorization"), "Bearer dummy")

        var keyless = URLRequest(url: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!)
        CustomClient().authorizeStreamRequest(&keyless, key: "")
        XCTAssertNil(keyless.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Check-in tap before the chat exists (finding 10)

    func testCheckInTapIsKeptUntilTheChatConsumesIt() {
        _ = CoachCheckIn.consumePendingOpen()
        XCTAssertFalse(CoachCheckIn.consumePendingOpen())
        CoachCheckIn.markPendingOpen()
        XCTAssertTrue(CoachCheckIn.consumePendingOpen())
        XCTAssertFalse(CoachCheckIn.consumePendingOpen(), "one tap runs one check-in")
    }
}
