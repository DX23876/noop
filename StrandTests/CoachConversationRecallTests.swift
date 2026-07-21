import XCTest
@testable import Strand

/// Cross-conversation recall — the reported failure was "Was habe ich dich gestern gefragt?" answered
/// with nothing at all.
///
/// Four independent defects produced that, and each has a test here:
///   1. the tool path carried no clock, so "yesterday" had nothing to resolve against;
///   2. it carried no hint that past threads exist, so the model never searched;
///   3. the search itself was keyword-only — a temporal question has no keywords, so it scored every
///      thread at zero;
///   4. the snippet returned the summary or the LAST message (the coach's own reply), never the user's
///      question, so even a hit couldn't answer "what did *I* ask".
///
/// Driven through the static, pure entry points (`recallText`, `threadsIndex`) with an injected `now`:
/// the engine's `conversations` is `private(set)`, and a test that built "yesterday" off the wall clock
/// would flake across midnight. `@MainActor` because `AICoachEngine` is, so its statics are too.
@MainActor
final class CoachConversationRecallTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed reference "now" so "yesterday" is deterministic: 2026-07-21, 12:00 local.
    private var now: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 21; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private func daysBefore(_ days: Int, hour: Int = 9) -> Date {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        return Calendar.current.date(bySettingHour: hour, minute: 30, second: 0, of: start)!
    }

    /// A thread whose turns all sit on one day. `summary: nil` on purpose — the common real case, since
    /// `MemoryMaintainer` only writes one when the user leaves a chat with enough new turns.
    private func thread(title: String,
                        daysAgo: Int,
                        asked: [String],
                        replied: String = "Here's my read.",
                        summary: String? = nil) -> CoachConversation {
        let stamp = daysBefore(daysAgo)
        var messages: [ChatMessage] = []
        for question in asked {
            messages.append(ChatMessage(role: .user, text: question, date: stamp))
            messages.append(ChatMessage(role: .assistant, text: replied, date: stamp))
        }
        return CoachConversation(title: title, createdAt: stamp, updatedAt: stamp,
                                 messages: messages, summary: summary)
    }

    // MARK: - Defect 3: a purely temporal question must work with NO query

    func testYesterdayIsFoundWithNoQueryAndNoSummary() {
        let convos = [thread(title: "Sleep debt", daysAgo: 1, asked: ["Wie hole ich Schlafschuld auf?"])]
        let text = AICoachEngine.recallText(convos, activeID: nil, onDaysAgo: 1, now: now)

        XCTAssertTrue(text.contains("Sleep debt"),
                      "on_days_ago:1 alone must find yesterday's thread — the reported bug was that a "
                      + "question with no keywords found nothing. Got: \(text)")
        XCTAssertFalse(text.contains("No conversations"))
    }

    func testDayBeforeYesterdayIsExcludedFromYesterday() {
        let convos = [thread(title: "Two days back", daysAgo: 2, asked: ["Was war das für ein Lauf?"])]
        let text = AICoachEngine.recallText(convos, activeID: nil, onDaysAgo: 1, now: now)

        XCTAssertFalse(text.contains("Two days back"), "on_days_ago is ONE day, not a window")
        XCTAssertTrue(text.contains("yesterday"), "the miss should name the day asked for: \(text)")
    }

    func testSinceDaysIsAWindowNotASingleDay() {
        let convos = [thread(title: "Three days back", daysAgo: 3, asked: ["Frage A"]),
                      thread(title: "Ten days back", daysAgo: 10, asked: ["Frage B"])]
        let text = AICoachEngine.recallText(convos, activeID: nil, sinceDays: 7, now: now)

        XCTAssertTrue(text.contains("Three days back"), "inside the 7-day window")
        XCTAssertFalse(text.contains("Ten days back"), "outside it")
    }

    /// Calendar days, not 24-hour arithmetic: a turn at 23:00 last night is "yesterday" at 00:30 today,
    /// even though barely 90 minutes passed.
    func testYesterdayIsCalendarDayNotTwentyFourHours() {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 21; c.hour = 0; c.minute = 30
        let justAfterMidnight = Calendar.current.date(from: c)!
        var lateLastNight = DateComponents()
        lateLastNight.year = 2026; lateLastNight.month = 7; lateLastNight.day = 20; lateLastNight.hour = 23
        let stamp = Calendar.current.date(from: lateLastNight)!

        XCTAssertEqual(AICoachEngine.daysAgo(stamp, now: justAfterMidnight), 1,
                       "23:00 → 00:30 is 1.5 hours but ONE calendar day")
    }

    // MARK: - Defect 4: the snippet must carry the USER's question, not the coach's reply

    func testResultQuotesTheUsersOwnQuestion() {
        let convos = [thread(title: "Recovery", daysAgo: 1,
                             asked: ["Warum ist meine Charge so niedrig?"],
                             replied: "Deine HRV liegt unter Baseline.")]
        let text = AICoachEngine.recallText(convos, activeID: nil, onDaysAgo: 1, now: now)

        XCTAssertTrue(text.contains("Warum ist meine Charge so niedrig?"),
                      "the user's question is the whole answer to 'what did I ask' — got: \(text)")
        XCTAssertFalse(text.contains("Deine HRV liegt unter Baseline."),
                       "the coach's own reply is not what was asked")
    }

    func testOnlyTurnsFromTheRequestedDayAreQuoted() {
        // One thread the user kept using across two days: asking about yesterday must not leak today.
        var convo = thread(title: "Long runner", daysAgo: 1, asked: ["Frage von gestern"])
        convo.messages.append(ChatMessage(role: .user, text: "Frage von heute", date: daysBefore(0)))
        convo.updatedAt = daysBefore(0)

        let text = AICoachEngine.recallText([convo], activeID: nil, onDaysAgo: 1, now: now)

        XCTAssertTrue(text.contains("Frage von gestern"))
        XCTAssertFalse(text.contains("Frage von heute"),
                       "filtering is per MESSAGE date, not the thread's updatedAt")
    }

    func testAutoOnlyThreadIsLabelledRatherThanReturnedBare() {
        let brief = CoachConversation(title: "Today's brief", updatedAt: daysBefore(1),
                                      messages: [ChatMessage(role: .assistant, text: "Rest up.",
                                                             date: daysBefore(1))])
        let text = AICoachEngine.recallText([brief], activeID: nil, onDaysAgo: 1, now: now)

        XCTAssertTrue(text.contains("coach-initiated"),
                      "a brief the user never replied to has no question to quote — say so: \(text)")
    }

    func testLongQuestionIsTruncatedNotDropped() {
        let long = String(repeating: "sehr lange Frage ", count: 40)
        let convos = [thread(title: "Wordy", daysAgo: 1, asked: [long])]
        let text = AICoachEngine.recallText(convos, activeID: nil, onDaysAgo: 1, now: now)

        XCTAssertTrue(text.contains("…"), "over-long turns are trimmed, not omitted")
        XCTAssertLessThan(text.count, long.count, "the trim must actually bound the result")
    }

    // MARK: - Keyword axis still works, and combines with time

    func testKeywordSearchStillWorksWithoutATimeFilter() {
        let convos = [thread(title: "Schlaf", daysAgo: 5, asked: ["Wie verbessere ich meinen Schlaf?"]),
                      thread(title: "Laufen", daysAgo: 6, asked: ["Wie schnell soll ich laufen?"])]
        let text = AICoachEngine.recallText(convos, activeID: nil, query: "Schlaf", now: now)

        XCTAssertTrue(text.contains("Schlaf"))
        XCTAssertFalse(text.contains("Laufen"), "a keyword-only search still requires an actual hit")
    }

    func testKeywordMissWithoutTimeFilterReportsTheQuery() {
        let convos = [thread(title: "Schlaf", daysAgo: 5, asked: ["Wie verbessere ich meinen Schlaf?"])]
        let text = AICoachEngine.recallText(convos, activeID: nil, query: "Radfahren", now: now)

        XCTAssertTrue(text.contains("Radfahren"),
                      "a keyword miss must be distinguishable from an empty day: \(text)")
    }

    func testActiveConversationIsExcluded() {
        let convo = thread(title: "The current chat", daysAgo: 1, asked: ["Frage"])
        let text = AICoachEngine.recallText([convo], activeID: convo.id, onDaysAgo: 1, now: now)

        XCTAssertFalse(text.contains("The current chat"), "the model already has the active transcript")
    }

    func testEmptyStoreIsAFriendlyLineNotACrash() {
        let text = AICoachEngine.recallText([], activeID: nil, onDaysAgo: 1, now: now)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("yesterday"))
    }

    // MARK: - Defect 2: the model must know past threads exist at all

    func testThreadsIndexListsTitlesWithRelativeDates() {
        let convos = [thread(title: "Gestern: Schlaf", daysAgo: 1, asked: ["Frage"]),
                      thread(title: "Heute: Lauf", daysAgo: 0, asked: ["Frage"])]
        let index = AICoachEngine.threadsIndex(convos, activeID: nil, now: now)

        XCTAssertTrue(index.contains("Gestern: Schlaf"))
        XCTAssertTrue(index.contains("yesterday"), "relative dates are what a temporal question needs")
        XCTAssertTrue(index.contains("today"))
        XCTAssertTrue(index.contains("search_past_conversations"),
                      "the index must point at the tool that reads a thread, or it's a dead end")
    }

    func testThreadsIndexIsEmptyWithNothingToShow() {
        XCTAssertTrue(AICoachEngine.threadsIndex([], activeID: nil, now: now).isEmpty,
                      "an empty block would add a stray heading to every request")
    }

    func testThreadsIndexSkipsEmptyThreads() {
        let blank = CoachConversation(title: "New chat", updatedAt: daysBefore(1))
        XCTAssertTrue(AICoachEngine.threadsIndex([blank], activeID: nil, now: now).isEmpty)
    }
}

/// The tool CONTRACT for recall. Separate from the logic above because a wrong schema breaks it just as
/// completely as wrong logic: if `query` stays required, the model cannot express "yesterday" at all.
@MainActor
final class CoachRecallToolSchemaTests: XCTestCase {

    private var schema: [String: Any] { CoachTool.searchPastConversations.inputSchema }

    func testNoParameterIsRequired() {
        XCTAssertNil(schema["required"],
                     "a purely temporal question carries no keywords — requiring `query` is exactly "
                     + "what made 'what did I ask you yesterday' unanswerable")
    }

    func testTimeParametersAreOffered() {
        let props = schema["properties"] as? [String: Any]
        XCTAssertNotNil(props?["on_days_ago"], "the single-day axis")
        XCTAssertNotNil(props?["since_days"], "the window axis")
        XCTAssertNotNil(props?["query"], "the keyword axis must survive")
    }

    /// The model only reaches for a tool its description covers, so the temporal case has to be spelled
    /// out there — a correct schema nobody invokes fixes nothing.
    func testDescriptionDirectsTheTemporalCase() {
        let text = CoachTool.searchPastConversations.description
        XCTAssertTrue(text.contains("on_days_ago"))
        XCTAssertTrue(text.lowercased().contains("yesterday"))
    }

    // MARK: - Argument coercion: providers disagree on how a JSON integer arrives

    func testIntArgAcceptsIntDoubleAndString() {
        XCTAssertEqual(AICoachEngine.intArg(1), 1)
        XCTAssertEqual(AICoachEngine.intArg(1.0), 1)
        XCTAssertEqual(AICoachEngine.intArg("1"), 1)
    }

    func testIntArgKeepsAbsentDistinctFromZero() {
        XCTAssertNil(AICoachEngine.intArg(nil),
                     "absent means 'no day filter'; 0 means 'today' — collapsing them would make every "
                     + "keyword search silently today-only")
    }
}

/// Defect 1: the tool path (Anthropic — the MAIN path) sent `planContextBlock()` and nothing else, so
/// the model had no date in context. Without it "yesterday" is not a resolvable concept, and no amount
/// of tool-schema work helps: the model cannot pick `on_days_ago: 1` if it doesn't know what today is.
@MainActor
final class CoachToolModeContextTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-toolmode-\(UUID().uuidString)"))
    }

    func testToolPathContextCarriesTheClock() {
        let context = makeEngine().toolModeContext
        XCTAssertTrue(context.contains("Right now:"),
                      "the tool path had no clock at all — got: \(context)")
    }

    /// The clock must NOT migrate into the system prompt: that block carries Anthropic's `cache_control`
    /// breakpoint, so a string containing the time of day would invalidate the prefix cache every turn.
    func testClockStaysOutOfTheCachedSystemPrompt() {
        XCTAssertFalse(makeEngine().systemPrompt.contains("Right now:"),
                       "a per-request clock in the cached system block would defeat prompt caching")
    }
}
