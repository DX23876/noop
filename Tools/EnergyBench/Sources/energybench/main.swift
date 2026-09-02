import Darwin
import Foundation
import StrandAnalytics

@main
struct EnergyBench {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            writeError("usage: swift run energybench <validation.csv>\n")
            exit(64)
        }
        let data = try String(contentsOfFile: arguments[1], encoding: .utf8)
        let samples = try parseCSV(data)
        let report = EnergyValidation.evaluate(samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !report.passedReleaseGate { exit(2) }
    }

    private static func parseCSV(_ text: String) throws -> [EnergyValidationSample] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first else { throw BenchError("CSV is empty") }
        let header = csvFields(first)
        let required = ["cohort", "participant_id", "context", "ground_truth_kcal", "noop_kcal"]
        for name in required where !header.contains(name) {
            throw BenchError("missing required column: \(name)")
        }
        let columns = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        func field(_ name: String, _ fields: [String]) -> String {
            guard let index = columns[name], fields.indices.contains(index) else { return "" }
            return fields[index].trimmingCharacters(in: .whitespaces)
        }

        return try lines.dropFirst().enumerated().compactMap { offset, line in
            let fields = csvFields(line)
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return nil }
            let number = offset + 2
            guard let cohort = EnergyValidationSample.Cohort(rawValue: field("cohort", fields)) else {
                throw BenchError("line \(number): invalid cohort")
            }
            guard let context = EnergyContext(rawValue: field("context", fields)) else {
                throw BenchError("line \(number): invalid context")
            }
            guard let truth = Double(field("ground_truth_kcal", fields)),
                  let noop = Double(field("noop_kcal", fields)) else {
                throw BenchError("line \(number): invalid required kcal value")
            }
            let apple = Double(field("apple_watch_kcal", fields))
            let low = Double(field("noop_low_kcal", fields))
            let high = Double(field("noop_high_kcal", fields))
            if (low == nil) != (high == nil) {
                throw BenchError("line \(number): noop interval needs both low and high")
            }
            let interval = try low.flatMap { lower -> ClosedRange<Double>? in
                guard let high, lower <= high else {
                    throw BenchError("line \(number): invalid noop interval")
                }
                return lower...high
            }
            return .init(cohort: cohort, participantID: field("participant_id", fields),
                         context: context, groundTruthKcal: truth, noopKcal: noop,
                         appleWatchKcal: apple, noopIntervalKcal: interval)
        }
    }

    /// Small RFC-4180 field reader: commas and doubled quotes inside quoted participant ids remain
    /// intact. Newlines inside fields are intentionally unsupported because every sample is one row.
    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if quoted, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                    continue
                }
                quoted.toggle()
            } else if character == ",", !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(current)
        return fields
    }

    private static func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

private struct BenchError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
