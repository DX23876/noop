import XCTest
@testable import Strand

/// Pins `CustomClient.parseChatContent` — the pure unwrap of an OpenAI-compatible chat-completions body
/// — and, above all, the truncation note it appends.
///
/// The note matters because `finish_reason: "length"` is ambiguous by design: it says a length limit was
/// hit, never which one. Its two realistic causes want opposite advice — a local Ollama's tiny 2048-token
/// context versus a hosted gateway's output cap — so the note is split by where the server actually is.
/// Telling an OpenRouter user to edit a Modelfile is not just useless, it names a cause that isn't theirs.
final class CustomChatContentTests: XCTestCase {

    private let client = CustomClient()

    private func body(_ content: String, finishReason: String?) -> [String: Any] {
        var choice: [String: Any] = ["message": ["role": "assistant", "content": content]]
        if let finishReason { choice["finish_reason"] = finishReason }
        return ["choices": [choice]]
    }

    // MARK: - Happy path

    func testReturnsContentUntouchedWhenTheReplyFinishedNormally() throws {
        let text = try client.parseChatContent(body("All good.", finishReason: "stop"), isLocalServer: false)
        XCTAssertEqual(text, "All good.", "a complete reply must carry no note")
    }

    func testAbsentFinishReasonIsTreatedAsComplete() throws {
        let text = try client.parseChatContent(body("All good.", finishReason: nil), isLocalServer: true)
        XCTAssertEqual(text, "All good.")
    }

    func testMissingContentIsADecodeError() {
        XCTAssertThrowsError(try client.parseChatContent(["choices": [[:]]], isLocalServer: false))
        XCTAssertThrowsError(try client.parseChatContent([:], isLocalServer: false))
    }

    // MARK: - Truncation note

    func testTruncatedReplyKeepsTheTextAndAppendsANote() throws {
        let text = try client.parseChatContent(body("You're at 83 today, which is a",
                                                    finishReason: "length"), isLocalServer: false)
        XCTAssertTrue(text.hasPrefix("You're at 83 today, which is a"),
                      "the partial answer must survive — it's still worth reading")
        XCTAssertTrue(text.contains("Reply cut off"))
    }

    func testFinishReasonMatchIsCaseInsensitive() throws {
        let text = try client.parseChatContent(body("cut", finishReason: "LENGTH"), isLocalServer: false)
        XCTAssertTrue(text.contains("Reply cut off"))
    }

    /// The regression this file exists for: a hosted gateway must not be handed Ollama instructions.
    func testHostedServerNoteDoesNotMentionOllama() {
        let note = CustomClient.truncationNote(isLocalServer: false)
        XCTAssertFalse(note.lowercased().contains("ollama"),
                       "Ollama advice is meaningless to someone pointed at a hosted gateway")
        XCTAssertFalse(note.contains("num_ctx"))
        XCTAssertTrue(note.contains("output limit"), "it should say what to actually do instead")
    }

    func testLocalServerNoteKeepsTheOllamaFix() {
        let note = CustomClient.truncationNote(isLocalServer: true)
        XCTAssertTrue(note.contains("Ollama"))
        XCTAssertTrue(note.contains("num_ctx"), "the concrete fix is the whole value of this note")
    }

    /// Neither note may assert the context window as the cause — `finish_reason: "length"` never says so,
    /// and on a hosted gateway it's usually the output cap instead.
    func testNeitherNoteClaimsToKnowWhichLimitWasHit() {
        for isLocal in [true, false] {
            let note = CustomClient.truncationNote(isLocalServer: isLocal)
            XCTAssertTrue(note.contains("stopped at a length limit"),
                          "state the fact the API gives us")
            XCTAssertFalse(note.contains("hit its context-window limit"),
                           "that was the old claim, and it was a guess dressed as a diagnosis")
        }
    }

    // MARK: - Local-vs-hosted classification

    /// `isLocalCustomServer` reads the saved base URL, so drive it through the real setting.
    func testBaseURLClassificationDecidesWhichAdviceApplies() {
        let key = AIProvider.customBaseURLKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set("http://localhost:11434/v1", forKey: key)
        XCTAssertTrue(CustomClient.isLocalCustomServer, "localhost is the Ollama case")

        UserDefaults.standard.set("http://192.168.1.50:11434/v1", forKey: key)
        XCTAssertTrue(CustomClient.isLocalCustomServer, "a LAN host is still local")

        UserDefaults.standard.set("https://openrouter.ai/api/v1", forKey: key)
        XCTAssertFalse(CustomClient.isLocalCustomServer, "a hosted gateway is not local")

        UserDefaults.standard.set("", forKey: key)
        XCTAssertFalse(CustomClient.isLocalCustomServer, "no URL must not be mistaken for local")
    }
}
