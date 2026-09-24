import Foundation
import CoachEvalCore

// coach-eval — see Package.swift and README.md.
//
//   coach-eval oracle                       reference specs through the executor; must be 100 %
//   coach-eval list   [--set smoke|full] [--lang en|de]
//   coach-eval run    --provider anthropic|openai|gemini --model <id> [--set smoke|full] [--lang en|de]
//                     [--limit N] [--out results.json]      (calls the provider; costs money)
//   coach-eval report results.json [more.json …]

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let cohort = SyntheticCohort.make()
let full = QuestionBank.all(cohort: cohort)
let set = option("--set") ?? "smoke"
let language = option("--lang") ?? "en"
var questions = set == "full" ? full : QuestionBank.smoke(from: full)
if let limit = option("--limit").flatMap(Int.init) { questions = Array(questions.prefix(limit)) }

switch arguments.first {
case "oracle":
    let results = Runner.oracle(full, cohort: cohort)
    let failures = results.filter { !$0.2 }
    print("Oracle: \(results.count - failures.count)/\(results.count) reference answers scored correct.")
    for (question, text, _) in failures.prefix(10) {
        print("\n✗ \(question.id): expected \(question.expected)\n\(text)")
    }
    exit(failures.isEmpty ? 0 : 1)

case "list":
    for question in questions { print("\(question.id)\t\(question.text(language))") }
    print("\(questions.count) questions (\(set)).")

case "run":
    guard let providerName = option("--provider"), let model = option("--model") else {
        fail("run needs --provider and --model")
    }
    let provider: EvalProvider
    do { provider = try Providers.make(providerName, model: model) } catch { fail(String(describing: error)) }
    print("Running \(questions.count) questions (\(set), \(language)) against \(providerName) · \(model)…")
    let records = await Runner.run(questions, cohort: cohort, provider: provider, language: language) { record in
        let mark = record.error != nil ? "!" : (record.correct ? "✓" : "✗")
        print("\(mark) \(record.id)  \(record.transcript.inputTokens + record.transcript.outputTokens) tok"
              + (record.error.map { "  \($0)" } ?? ""))
    }
    if let out = option("--out") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(records).write(to: URL(fileURLWithPath: out)) } catch { fail("could not write \(out): \(error)") }
        print("Wrote \(out).")
    }
    print("\n" + Runner.report(records))

case "report":
    let files = arguments.dropFirst()
    guard !files.isEmpty else { fail("report needs at least one results file") }
    var records: [EvalRecord] = []
    for path in files {
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode([EvalRecord].self, from: data) else { fail("could not read \(path)") }
        records += decoded
    }
    print(Runner.report(records))

default:
    fail("usage: coach-eval oracle | list | run | report   (see Sources/coach-eval/main.swift)")
}
