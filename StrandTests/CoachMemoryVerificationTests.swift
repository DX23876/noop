import XCTest
@testable import Strand

@MainActor
final class CoachMemoryVerificationTests: XCTestCase {
    private func memory() -> CoachMemory {
        let name = "CoachMemoryVerificationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return CoachMemory(defaults: defaults)
    }

    func testHealthFactNeedsConfirmationBeforePinnedUse() {
        let memory = memory()
        XCTAssertTrue(memory.add("Linkes Knie ist verletzt.",
                                 category: .injury,
                                 importance: .pinned))
        let fact = try! XCTUnwrap(memory.facts.first)

        XCTAssertEqual(fact.verification, .pendingConfirmation)
        XCTAssertEqual(fact.sensitivity, .health)
        XCTAssertEqual(fact.source, .user)
        XCTAssertEqual(fact.evidence.count, 1)
        XCTAssertTrue(memory.pinnedBlock.isEmpty)

        memory.confirm(fact.id)
        XCTAssertTrue(memory.pinnedBlock.contains("Linkes Knie ist verletzt."))
    }

    func testPreferenceStartsAsHypothesisAndEditKeepsRevision() {
        let memory = memory()
        XCTAssertTrue(memory.add("Joggen am Wochenende passt selten.",
                                 category: .preference))
        let fact = try! XCTUnwrap(memory.facts.first)
        XCTAssertEqual(fact.verification, .hypothesis)

        XCTAssertTrue(memory.update(fact.id,
                                    text: "Joggen am Samstag passt selten.",
                                    confirmedByUser: true))
        let updated = try! XCTUnwrap(memory.facts.first)
        XCTAssertEqual(updated.verification, .confirmed)
        XCTAssertEqual(updated.revisions.map(\.previousText),
                       ["Joggen am Wochenende passt selten."])
    }

    func testRestatementAddsBoundedEvidenceAndPreservesSource() {
        let memory = memory()
        XCTAssertTrue(memory.add("Prefers cycling before work",
                                 category: .preference,
                                 source: .conversationSummary,
                                 referenceID: "chat-1"))
        XCTAssertTrue(memory.add("Prefers cycling before work",
                                 category: .preference,
                                 source: .coachTool))

        let fact = try! XCTUnwrap(memory.facts.first)
        XCTAssertEqual(fact.source, .conversationSummary)
        XCTAssertEqual(fact.evidenceCount, 2)
        XCTAssertEqual(fact.evidence.map(\.source), [.conversationSummary, .coachTool])
        XCTAssertEqual(fact.evidence.first?.referenceID, "chat-1")
    }

    func testDistilledHealthAndGoalLanguageRequiresConfirmation() {
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Blood test showed low ferritin"),
                       .physiology)
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Training for a marathon in October"),
                       .goal)
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Likes quiet evening walks"),
                       .schedule)
    }

    /// The summariser writes in the user's own language, so a classifier that only reads English and
    /// German silently downgraded every distilled fact to `.preference` for six of the nine shipped
    /// locales — losing both the health sensitivity and the confirmation requirement.
    func testDistilledHealthLanguageIsRecognisedInEveryShippedLanguage() {
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Tiene una lesión en la rodilla"), .injury)
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Souffre d'une blessure au genou"), .injury)
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Ha un infortunio al ginocchio"), .injury)
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Tem uma lesão no joelho"), .injury)
        XCTAssertEqual(CoachMemory.inferredCategory(for: "У него травма колена"), .injury)
        XCTAssertEqual(CoachMemory.inferredCategory(for: "膝盖受伤了"), .injury)

        XCTAssertEqual(CoachMemory.inferredCategory(for: "Toma medicamento para la tensión"), .physiology)
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Принимает лекарство ежедневно"), .physiology)
    }

    /// The dangerous half of a substring classifier: terms short enough to appear inside unrelated
    /// words. These are the exact ones that had to be dropped, so nobody adds them back.
    func testEverydayWordsAreNotMistakenForHealthOrGoalLanguage() {
        XCTAssertNotEqual(CoachMemory.inferredCategory(for: "Has a high metabolic rate"), .goal,
                          "\"meta\" must not match inside \"metabolic\"")
        XCTAssertNotEqual(CoachMemory.inferredCategory(for: "Trains outdoors, but only in summer"), .goal,
                          "\"but\" must not be a goal term")
        XCTAssertNotEqual(CoachMemory.inferredCategory(for: "Prefers the outdoor track"), .injury,
                          "\"dor\" must not match inside \"outdoor\"")
    }

    // MARK: - Confirmation: the only way a health fact ever frames a reply

    /// `pinnedBlock` admits only confirmed facts, so without a confirmation path reachable from the
    /// conversation, every injury the coach saves is barred from the block it was pinned for. This is
    /// that path: the user stating it themselves.
    func testAFactTheUserStatedThemselvesIsConfirmedImmediately() {
        let memory = memory()
        XCTAssertTrue(memory.add("Left knee is injured.",
                                 category: .injury,
                                 importance: .pinned,
                                 source: .coachTool,
                                 confirmedByUser: true))
        let fact = try! XCTUnwrap(memory.facts.first)
        XCTAssertEqual(fact.verification, .confirmed)
        XCTAssertTrue(memory.pinnedBlock.contains("Left knee is injured."))
    }

    /// The restatement path is where a "yes, that's right" actually arrives — the coach re-saves a fact
    /// it already holds. That branch never wrote `verification`, so confirmation could not land at all.
    func testConfirmingARestatementOfAnExistingFactPromotesIt() {
        let memory = memory()
        XCTAssertTrue(memory.add("Left knee is injured.", category: .injury, importance: .pinned))
        XCTAssertEqual(memory.facts.first?.verification, .pendingConfirmation)
        XCTAssertTrue(memory.pinnedBlock.isEmpty, "premise: unconfirmed stays out of the block")

        XCTAssertTrue(memory.add("Left knee is injured.",
                                 category: .injury,
                                 importance: .pinned,
                                 source: .coachTool,
                                 confirmedByUser: true))
        XCTAssertEqual(memory.facts.count, 1, "a restatement must not stack a second fact")
        XCTAssertEqual(memory.facts.first?.verification, .confirmed)
        XCTAssertTrue(memory.pinnedBlock.contains("Left knee is injured."))
    }

    /// The other direction must never happen: the coach re-inferring a fact the user already confirmed
    /// cannot quietly demote it back out of the always-relevant block.
    func testARestatementWithoutConfirmationNeverDowngradesAConfirmedFact() {
        let memory = memory()
        XCTAssertTrue(memory.add("Left knee is injured.",
                                 category: .injury,
                                 importance: .pinned,
                                 confirmedByUser: true))
        XCTAssertTrue(memory.add("Left knee is injured.",
                                 category: .injury,
                                 importance: .pinned,
                                 source: .coachTool,
                                 confirmedByUser: false))
        XCTAssertEqual(memory.facts.first?.verification, .confirmed)
    }

    /// An inference is still an inference — the flag has to be OPT-IN or it means nothing.
    func testAnInferredHealthFactStillNeedsConfirmation() {
        let memory = memory()
        XCTAssertTrue(memory.add("Probably strained a calf.",
                                 category: .injury,
                                 source: .coachTool))
        XCTAssertEqual(memory.facts.first?.verification, .pendingConfirmation)
        XCTAssertTrue(memory.pinnedBlock.isEmpty)
    }

    // MARK: - Expiry

    /// A day-granular expiry must cover the whole day the user named, not expire at its first second.
    func testExpiryCoversTheWholeNamedDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let expiry = try! XCTUnwrap(CoachMemory.expiryDate(from: "2026-08-20", calendar: calendar))

        let noonThatDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12))!
        let nextMorning = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 9))!
        XCTAssertGreaterThan(expiry, noonThatDay, "still valid at midday on its last day")
        XCTAssertLessThan(expiry, nextMorning, "expired by the next morning")
    }

    /// Anything unparseable means "no expiry": a fact that outlives its date is a smaller error than one
    /// that silently vanishes because a model wrote the date in a shape we don't read.
    func testAMalformedExpiryMeansNoExpiry() {
        XCTAssertNil(CoachMemory.expiryDate(from: nil))
        XCTAssertNil(CoachMemory.expiryDate(from: ""))
        XCTAssertNil(CoachMemory.expiryDate(from: "next Tuesday"))
        XCTAssertNil(CoachMemory.expiryDate(from: "20.08.2026"))
    }

    func testAnExpiredFactStopsFramingReplies() {
        let memory = memory()
        let yesterday = Date().addingTimeInterval(-86_400)
        XCTAssertTrue(memory.add("Travelling, no gym access.",
                                 category: .schedule,
                                 importance: .pinned,
                                 confirmedByUser: true,
                                 validUntil: yesterday))
        XCTAssertTrue(memory.pinnedBlock.isEmpty, "an expired fact must leave the always-relevant block")
        XCTAssertTrue(memory.relevantFacts(for: "gym access while travelling", limit: 8).isEmpty)
    }

    /// A restatement that mentions no expiry must not resurrect a fact indefinitely, but a new date
    /// replaces the old one.
    func testARestatementReplacesAnExpiryButNeverClearsIt() {
        let memory = memory()
        let soon = Date().addingTimeInterval(86_400)
        let later = Date().addingTimeInterval(10 * 86_400)
        XCTAssertTrue(memory.add("Travelling, no gym access.", category: .schedule, validUntil: soon))
        XCTAssertTrue(memory.add("Travelling, no gym access.", category: .schedule))
        XCTAssertEqual(memory.facts.first?.validUntil, soon, "silence must not clear the expiry")

        XCTAssertTrue(memory.add("Travelling, no gym access.", category: .schedule, validUntil: later))
        XCTAssertEqual(memory.facts.first?.validUntil, later)
    }

    // MARK: - Eviction order

    /// An expired fact is invisible to every retrieval path, so it is the cheapest thing to lose — and
    /// before `validUntil` was ever written, this arm could not fire at all.
    func testEvictionDropsAnExpiredFactBeforeAnyLiveOne() {
        let now = Date()
        let live = CoachMemory.MemoryFact(text: "newest", createdAt: now)
        let expired = CoachMemory.MemoryFact(text: "expired",
                                             createdAt: now.addingTimeInterval(-100),
                                             validUntil: now.addingTimeInterval(-1))
        let oldest = CoachMemory.MemoryFact(text: "oldest", createdAt: now.addingTimeInterval(-1_000))
        let index = try! XCTUnwrap(CoachMemory.evictionIndex(in: [live, expired, oldest], now: now))
        XCTAssertEqual(index, 1)
    }

    func testEvictionOtherwiseDropsTheOldestUnpinnedFact() {
        let now = Date()
        let newest = CoachMemory.MemoryFact(text: "newest", createdAt: now)
        let oldPinned = CoachMemory.MemoryFact(text: "old but pinned",
                                              importance: .pinned,
                                              createdAt: now.addingTimeInterval(-1_000))
        let oldPlain = CoachMemory.MemoryFact(text: "old", createdAt: now.addingTimeInterval(-500))
        let index = try! XCTUnwrap(CoachMemory.evictionIndex(in: [newest, oldPlain, oldPinned], now: now))
        XCTAssertEqual(index, 1, "the pinned fact must survive being the oldest")
    }

    func testEvictionFallsBackToTheOldestWhenEverythingIsPinned() {
        let now = Date()
        let newest = CoachMemory.MemoryFact(text: "newest", importance: .pinned, createdAt: now)
        let oldest = CoachMemory.MemoryFact(text: "oldest",
                                            importance: .pinned,
                                            createdAt: now.addingTimeInterval(-1_000))
        XCTAssertEqual(CoachMemory.evictionIndex(in: [newest, oldest], now: now), 1)
    }

    // MARK: - What the settings card is allowed to claim

    /// The card used to say the coach "uses these in every reply", which was true of none of them. These
    /// are the four states it now distinguishes.
    func testReachCountsWhatActuallyGetsSent() {
        let now = Date()
        let alwaysOn = CoachMemory.MemoryFact(text: "pinned and confirmed",
                                              importance: .pinned,
                                              createdAt: now,
                                              verification: .confirmed)
        let pinnedButUnconfirmed = CoachMemory.MemoryFact(text: "pinned, not confirmed",
                                                          importance: .pinned,
                                                          createdAt: now,
                                                          verification: .pendingConfirmation)
        let ordinary = CoachMemory.MemoryFact(text: "ordinary", createdAt: now, verification: .confirmed)
        let expired = CoachMemory.MemoryFact(text: "over",
                                             createdAt: now,
                                             verification: .confirmed,
                                             validUntil: now.addingTimeInterval(-1))

        let reach = CoachMemory.reach(of: [alwaysOn, pinnedButUnconfirmed, ordinary, expired], now: now)
        XCTAssertEqual(reach.alwaysOn, 1, "only pinned AND confirmed frames every reply")
        XCTAssertEqual(reach.whenRelevant, 2, "a pinned-but-unconfirmed fact is not always-on")
        XCTAssertEqual(reach.awaitingConfirmation, 1)
        XCTAssertEqual(reach.expired, 1, "an expired fact is counted apart, not as reaching anything")
    }

    // MARK: - Near misses on the destructive tools

    /// `firstMatch` applies `.injury`'s thresholds to every category, so a phrasing that misses by a word
    /// finds nothing and the tool used to answer with a dead end. Candidates give the coach something to
    /// ask about — without loosening the rule on the path that actually deletes.
    func testCandidatesOfferWhatTheStrictMatchRefuses() {
        let memory = memory()
        XCTAssertTrue(memory.add("Runs on weekday mornings before work", category: .preference))

        XCTAssertNil(memory.firstMatch("runs in the mornings"),
                     "premise: the strict match still refuses this")
        XCTAssertEqual(memory.candidates(for: "runs in the mornings").map(\.text),
                       ["Runs on weekday mornings before work"])
    }

    /// A candidate is a near miss, not a free-for-all: an unrelated fact must not be offered.
    func testCandidatesStayEmptyForAnUnrelatedQuery() {
        let memory = memory()
        XCTAssertTrue(memory.add("Runs on weekday mornings before work", category: .preference))
        XCTAssertTrue(memory.candidates(for: "lactose intolerance diagnosis").isEmpty)
    }

    /// What `firstMatch` already found is not a "did you mean" — it is the answer.
    func testCandidatesExcludeTheExactMatch() {
        let memory = memory()
        XCTAssertTrue(memory.add("Runs on weekday mornings before work", category: .preference))
        XCTAssertNotNil(memory.firstMatch("Runs on weekday mornings before work"), "premise")
        XCTAssertTrue(memory.candidates(for: "Runs on weekday mornings before work").isEmpty)
    }

    // MARK: - The user's own controls

    func testPinningIsReachableWithoutTheModel() {
        let memory = memory()
        XCTAssertTrue(memory.add("No gym on Wednesdays.", category: .schedule, confirmedByUser: true))
        let id = try! XCTUnwrap(memory.facts.first?.id)
        XCTAssertTrue(memory.pinnedBlock.isEmpty, "premise: not pinned yet")

        memory.setImportance(id, .pinned)
        XCTAssertTrue(memory.pinnedBlock.contains("No gym on Wednesdays."))

        memory.setImportance(id, .normal)
        XCTAssertTrue(memory.pinnedBlock.isEmpty)
    }

    /// The user correcting their own memory may clear an expiry outright — unlike a coach restatement,
    /// which can only ever replace one.
    func testTheUserCanRetireAndReviveAFact() {
        let memory = memory()
        XCTAssertTrue(memory.add("Travelling, no gym access.", category: .schedule, confirmedByUser: true))
        let fact = try! XCTUnwrap(memory.facts.first)

        memory.setValidUntil(fact.id, Date().addingTimeInterval(-1))
        XCTAssertFalse(memory.isActive(try! XCTUnwrap(memory.facts.first)))

        memory.setValidUntil(fact.id, nil)
        XCTAssertTrue(memory.isActive(try! XCTUnwrap(memory.facts.first)))
    }
}
