import XCTest
@testable import Strand

/// Gemini's tool-calling and streaming wire format. Gemini was the last provider on the pre-baked
/// context path — no `propose_plan`, no `remember_fact`, no `plot_metric`, and no visible reply until the
/// whole thing had arrived.
///
/// Its format differs from the OpenAI one in three ways that each break the integration silently rather
/// than loudly, which is what these tests pin: an unsupported schema keyword rejects the ENTIRE request
/// (so every tool vanishes at once), a `functionResponse` must carry an object, and roles are
/// `user`/`model` with no `assistant` and no tool role.
@MainActor
final class GeminiToolsTests: XCTestCase {

    private func json(_ raw: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - Schema reduction: the failure that takes every tool with it

    func testUnsupportedKeywordsAreDropped() {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["days": ["type": "integer", "minimum": 1, "maximum": 365,
                                    "description": "how many days"]],
            "required": ["days"]
        ]
        let reduced = CoachTool.geminiSchema(schema)
        let props = reduced["properties"] as? [String: Any]
        let days = props?["days"] as? [String: Any]

        XCTAssertNil(days?["minimum"], "Gemini's Schema type rejects the whole request over a keyword "
                     + "it doesn't model — one stray bound costs every tool")
        XCTAssertNil(days?["maximum"])
        XCTAssertEqual(days?["type"] as? String, "integer", "the parts it does model must survive")
        XCTAssertEqual(days?["description"] as? String, "how many days")
        XCTAssertEqual(reduced["required"] as? [String], ["days"])
    }

    func testReductionRecursesIntoNestedItems() {
        let schema: [String: Any] = [
            "type": "array",
            "items": ["type": "object",
                      "properties": ["n": ["type": "integer", "minimum": 0]]]
        ]
        let items = CoachTool.geminiSchema(schema)["items"] as? [String: Any]
        let n = (items?["properties"] as? [String: Any])?["n"] as? [String: Any]

        XCTAssertNil(n?["minimum"], "a bound buried two levels down rejects the request just as hard")
        XCTAssertEqual(n?["type"] as? String, "integer")
    }

    /// The real schemas are what actually ship, so reduce every one of them and assert nothing
    /// unsupported survives anywhere.
    func testEveryRealToolSchemaReducesCleanly() {
        let supported: Set<String> = ["type", "description", "properties", "required", "items",
                                      "enum", "format", "nullable"]

        func assertClean(_ schema: [String: Any], tool: String, path: String = "") {
            for (key, value) in schema {
                XCTAssertTrue(supported.contains(key),
                              "\(tool)\(path): '\(key)' is not in Gemini's Schema type")
                if key == "properties", let props = value as? [String: Any] {
                    for (name, sub) in props {
                        if let sub = sub as? [String: Any] {
                            assertClean(sub, tool: tool, path: "\(path).\(name)")
                        }
                    }
                } else if key == "items", let sub = value as? [String: Any] {
                    assertClean(sub, tool: tool, path: "\(path)[]")
                }
            }
        }

        for tool in CoachTool.allCases {
            let spec = tool.geminiFunctionSpec
            XCTAssertEqual(spec["name"] as? String, tool.rawValue)
            XCTAssertFalse((spec["description"] as? String ?? "").isEmpty)
            assertClean(spec["parameters"] as? [String: Any] ?? [:], tool: tool.rawValue)
        }
    }

    // MARK: - Roles

    func testAssistantBecomesModel() {
        let contents = GeminiClient.contents(from: [(role: .user, content: "hi"),
                                                    (role: .assistant, content: "hello")])
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        XCTAssertEqual(contents[1]["role"] as? String, "model",
                       "Gemini has no 'assistant' role and rejects it")
    }

    // MARK: - Parsing a response / chunk

    func testTextPartsAreJoined() {
        let parsed = GeminiClient.parseCandidate(json("""
        {"candidates":[{"content":{"parts":[{"text":"Teil 1 "},{"text":"Teil 2"}]}}]}
        """))
        XCTAssertEqual(parsed.text, "Teil 1 Teil 2", "a thinking model emits more than one text part")
        XCTAssertTrue(parsed.calls.isEmpty)
    }

    func testFunctionCallIsParsedWithDecodedArgs() {
        let parsed = GeminiClient.parseCandidate(json("""
        {"candidates":[{"content":{"parts":[
          {"functionCall":{"name":"get_range_report","args":{"days":30}}}
        ]}}]}
        """))
        XCTAssertEqual(parsed.calls.count, 1)
        XCTAssertEqual(parsed.calls.first?.name, "get_range_report")
        XCTAssertEqual(parsed.calls.first?.args["days"] as? Int, 30,
                       "args arrive decoded — unlike OpenAI there is no JSON string to reassemble")
    }

    func testEmptyOrUnexpectedBodyParsesToNothingRatherThanThrowing() {
        XCTAssertEqual(GeminiClient.parseCandidate([:]).text, "")
        XCTAssertTrue(GeminiClient.parseCandidate(json("""
        {"promptFeedback":{"blockReason":"SAFETY"}}
        """)).calls.isEmpty, "a chunk with no candidates must not abort the stream")
    }

    // MARK: - The turns sent back

    func testFunctionResponseWrapsTextInAnObject() async {
        var called: [String] = []
        let turn = await GeminiClient.functionResponseTurn(
            for: [GeminiFunctionCall(name: "get_readiness", args: [:])],
            runTool: { _, _ in "READINESS (primed): good to go" },
            called: &called)

        XCTAssertEqual(turn["role"] as? String, "user", "there is no tool role in the REST shape")
        let parts = turn["parts"] as? [[String: Any]]
        let fr = parts?.first?["functionResponse"] as? [String: Any]
        let response = fr?["response"] as? [String: Any]

        XCTAssertEqual(response?["result"] as? String, "READINESS (primed): good to go",
                       "`response` must be an OBJECT — a bare string is rejected")
        XCTAssertEqual(called, ["get_readiness"], "the evidence chain records the call")
    }

    func testModelTurnEchoesTheCalls() {
        let turn = GeminiClient.modelTurn(for: [GeminiFunctionCall(name: "get_readiness", args: [:])])
        XCTAssertEqual(turn["role"] as? String, "model")
        let fc = (turn["parts"] as? [[String: Any]])?.first?["functionCall"] as? [String: Any]
        XCTAssertEqual(fc?["name"] as? String, "get_readiness")
    }

    // MARK: - Request body and URL

    func testToolsAreOfferedUnderFunctionDeclarations() {
        let body = GeminiClient.requestBody(systemPrompt: "sys", contents: [],
                                            tools: [.readiness, .chargeDrivers])
        let tools = body["tools"] as? [[String: Any]]
        let declarations = tools?.first?["functionDeclarations"] as? [[String: Any]]
        XCTAssertEqual(declarations?.count, 2)
    }

    func testNoToolsKeyWhenThereAreNoTools() {
        let body = GeminiClient.requestBody(systemPrompt: "sys", contents: [], tools: [])
        XCTAssertNil(body["tools"], "an empty tools array is not the same as omitting it")
    }

    func testOutputBudgetStaysAtGeminisOwnCeiling() {
        let config = GeminiClient.requestBody(systemPrompt: "s", contents: [],
                                              tools: [])["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["maxOutputTokens"] as? Int, 4096,
                       "Gemini counts THINKING tokens against this cap; a smaller visible-reply budget "
                       + "starves a thinking model into an empty answer")
    }

    func testStreamingUsesTheSSEEndpointWithAnUnescapedColon() {
        let req = GeminiClient.request(key: "k", model: "gemini-pro-latest", body: [:], streaming: true)
        let url = req.url?.absoluteString ?? ""

        XCTAssertTrue(url.hasSuffix(":streamGenerateContent?alt=sse"))
        XCTAssertFalse(url.contains("%3A"), "the API rejects a percent-encoded colon")
    }

    func testNonStreamingUsesGenerateContent() {
        let req = GeminiClient.request(key: "k", model: "gemini-pro-latest", body: [:], streaming: false)
        XCTAssertTrue((req.url?.absoluteString ?? "").hasSuffix(":generateContent"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "k")
    }

    // MARK: - The forcing close keeps the gathered data

    func testClosingContentsFoldToolResultsIntoTheFinalTurn() {
        var called: [String] = []
        let contents: [[String: Any]] = [
            ["role": "user", "parts": [["text": "Wie ist meine Readiness?"]]],
            GeminiClient.modelTurn(for: [GeminiFunctionCall(name: "get_readiness", args: [:])]),
            ["role": "user",
             "parts": [["functionResponse": ["name": "get_readiness",
                                             "response": ["result": "READINESS (primed)"]]]]]
        ]
        _ = called

        let closing = GeminiClient.closingContents(from: contents)
        let lastText = ((closing.last?["parts"] as? [[String: Any]])?.first?["text"] as? String) ?? ""

        XCTAssertTrue(lastText.contains("READINESS (primed)"),
                      "the closing instruction says 'using the data gathered above' — dropping the tool "
                      + "results would make that a lie")
        XCTAssertTrue(lastText.contains("Do not request more tools"))
        XCTAssertTrue(closing.allSatisfy { turn in
            let parts = turn["parts"] as? [[String: Any]] ?? []
            return parts.allSatisfy { $0["functionCall"] == nil && $0["functionResponse"] == nil }
        }, "the closing request carries no call/response parts — they have no endpoint anymore")
    }

    // MARK: - Wiring

    func testGeminiNowSpeaksBothProtocols() {
        XCTAssertTrue(AIProvider.gemini.client is ToolCallingClient)
        XCTAssertTrue(AIProvider.gemini.client is StreamingToolClient)
    }
}
