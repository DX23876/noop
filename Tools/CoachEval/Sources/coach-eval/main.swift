import Foundation
import CoachEvalCore

// coach-eval — see Package.swift and README.md.
//
//   coach-eval oracle                       reference specs through the executor; must be 100 %
//   coach-eval list   [--set smoke|full] [--lang en|de]
//   coach-eval run    --provider anthropic|openai|gemini --model <id> [--set smoke|full] [--lang en|de]
//                     [--limit N] [--out results.json]      (calls the provider; costs money)
//   coach-eval report results.json [more.json …]
//   coach-eval open   --provider <p> --model <id> --rater-provider <other p> --rater-model <id>
//                     [--lang en|de] [--limit N] [--out open.json]   (calls two providers; costs money)
//   coach-eval open-report open.json [more.json …]
//   coach-eval calibration-sheet open.json [--size 40]  > sheet.csv   (then grade it yourself)
//   coach-eval agreement sheet.csv open.json

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

case "open":
    guard let providerName = option("--provider"), let model = option("--model"),
          let raterName = option("--rater-provider"), let raterModel = option("--rater-model") else {
        fail("open needs --provider, --model, --rater-provider and --rater-model")
    }
    let provider: EvalProvider, rater: EvalProvider
    do {
        try Autorater.checkIndependence(answer: providerName, rater: raterName)
        provider = try Providers.make(providerName, model: model)
        rater = try Providers.make(raterName, model: raterModel)
    } catch { fail(String(describing: error)) }
    var open = OpenQuestionBank.all(cohort: cohort)
    if let limit = option("--limit").flatMap(Int.init) { open = Array(open.prefix(limit)) }
    print("Answering \(open.count) open questions (\(language)) with \(providerName) · \(model), rated by \(raterName) · \(raterModel)…")
    let records: [OpenRecord]
    do {
        records = try await Autorater.run(open, cohort: cohort, provider: provider, rater: rater, language: language) { record in
            let grade = record.rating.map { "\($0.overall)\($0.criticalSafetyIssue ? " CRITICAL" : "")" } ?? "–"
            print("\(record.id)  overall \(grade)" + (record.error.map { "  \($0)" } ?? ""))
        }
    } catch { fail(String(describing: error)) }
    if let out = option("--out") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(records).write(to: URL(fileURLWithPath: out)) } catch { fail("could not write \(out): \(error)") }
        print("Wrote \(out).")
    }
    print("\n" + Autorater.report(records))

case "open-report", "calibration-sheet", "agreement":
    let files = arguments.dropFirst().filter { !$0.hasPrefix("--") && $0 != option("--size") }
    func load(_ path: String) -> [OpenRecord] {
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode([OpenRecord].self, from: data) else { fail("could not read \(path)") }
        return decoded
    }
    switch arguments.first {
    case "open-report":
        guard !files.isEmpty else { fail("open-report needs at least one results file") }
        print(Autorater.report(files.flatMap(load)))
    case "calibration-sheet":
        guard let path = files.first else { fail("calibration-sheet needs an open results file") }
        print(Calibration.sheet(load(path), size: option("--size").flatMap(Int.init) ?? 40))
    default:
        guard files.count == 2, let csv = try? String(contentsOfFile: files[0], encoding: .utf8) else {
            fail("agreement needs the graded sheet.csv and the open results file")
        }
        print(Calibration.agreement(sheetCSV: csv, records: load(files[1])))
    }

default:
    fail("usage: coach-eval oracle | list | run | report | open | open-report | calibration-sheet | agreement")
}
