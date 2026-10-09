import Foundation
import GRDB
import WhoopStore
import WhoopProtocol
import StrandAnalytics

struct Beat: Codable {
    let ts: Int
    let rrMs: Int
    let ord: Int?
    let seq: Int
    let channel: Int?
    let transport: Int?
    let suspect: Int?
    init(_ rr: RRInterval) {
        ts = rr.ts; rrMs = rr.rrMs; ord = rr.ord; seq = rr.seq
        channel = rr.srcChannel?.rawValue; transport = rr.transport?.rawValue; suspect = nil
    }
    init(_ row: Row) {
        ts = row["ts"]; rrMs = row["rrMs"]; ord = row["ord"]; seq = row["seq"]
        channel = row["srcChannel"]; transport = row["transport"]; suspect = row["tsSuspect"]
    }
}
struct Analysis: Codable {
    let originalIndices: [Int]
    let contiguous: [Bool]
    let rmssd: Double?
    let nInput: Int
    let nClean: Int
    init(_ values: [Double]) {
        let clean = HRVAnalyzer.cleanRRGapAware(values)
        let result = HRVAnalyzer.analyze(rawRR: values)
        originalIndices = clean.originalIndices; contiguous = clean.contiguous
        rmssd = result.rmssd; nInput = values.count; nClean = clean.nn.count
    }
}
struct Export: Codable {
    let raw: [Beat]
    let selected: [Beat]
    let selectedAnalysis: Analysis
}
func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

@main enum Main {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--analyze"] {
            let batches = try JSONDecoder().decode([[Double]].self,
                from: FileHandle.standardInput.readDataToEndOfFile())
            try emit(batches.map(Analysis.init))
            return
        }
        guard args.count == 3, let from = Int(args[1]), let to = Int(args[2]), from <= to else {
            throw NSError(domain: "Usage: rr-reference-export DATABASE FROM TO | --analyze", code: 1)
        }
        let store = try WhoopStore.readOnly(path: args[0])
        // Select an owner, not an alias union. Refuse ambiguity rather than combine independent straps.
        let owners = try await store.registryWriter.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT deviceId FROM rrInterval WHERE ts BETWEEN ? AND ?",
                                arguments: [from, to])
        }
        guard owners.count == 1, let owner = owners.first else {
            throw NSError(domain: "Expected exactly one RR owner in the requested window", code: 2)
        }
        let raw = try await store.registryWriter.read { db in
            // Observation-only query. Source selection below calls the real app read API.
            try Row.fetchAll(db, sql: """
                SELECT ts, rrMs, ord, seq, srcChannel, transport, tsSuspect
                FROM rrInterval WHERE deviceId = ? AND ts BETWEEN ? AND ?
                ORDER BY ts, ord, rrMs, seq
                """, arguments: [owner, from, to]).map(Beat.init)
        }
        let selected = try await store.rrIntervals(deviceId: owner, from: from, to: to, limit: Int.max)
        try emit(Export(raw: raw, selected: selected.map(Beat.init),
                        selectedAnalysis: Analysis(selected.map { Double($0.rrMs) })))
    }
}
