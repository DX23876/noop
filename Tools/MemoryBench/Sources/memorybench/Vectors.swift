import Foundation
import SemanticMemory

/// A vectors set as `embed` writes it and `score` reads it.
///
/// Stored as Float16 through `SemanticVector.encodeFloat16`, which is the app's own on-disk encoding — so a
/// benchmark number includes the quantisation loss the product actually has, rather than scoring
/// full-precision vectors the device never sees.
struct VectorSetMeta: Codable {
    let model: String
    let pooling: String
    let queryTemplate: String
    let documentTemplate: String
    let fullDimensions: Int
    let storedDimensions: Int
    let matryoshka: Bool
    /// Chunk ids, in the order their vectors appear in `documents.f16`.
    let documentIDs: [String]
    /// Query ids, in the order their vectors appear in `queries.f16`.
    let queryIDs: [String]
    /// Wall-clock milliseconds the embedding run took, and how many texts it covered. The only cost figure
    /// this stage can honestly report — device latency has to be measured on a device.
    let embedMilliseconds: Double
    let embeddedTexts: Int
    /// Bytes of the GGUF this run used. Optional so vector sets written before it existed still decode —
    /// a required field would have made every earlier run unreadable, which is a bad trade for one number.
    ///
    /// It belongs beside quality because it is the cost the user actually pays twice: once in the download and
    /// once in resident memory. A model that wins by being four times larger should have to show that in the
    /// same table.
    var modelFileBytes: Int?
}

struct VectorSet {
    let meta: VectorSetMeta
    let documents: [String: [Float]]
    let queries: [String: [Float]]

    var dimensions: Int { meta.storedDimensions }

    /// Bytes the index would occupy for these documents, at the app's Float16 encoding. Reported beside
    /// quality so a model that wins by storing four times as much is visibly doing that.
    var indexBytes: Int { documents.count * meta.storedDimensions * 2 }

    static func write(directory: URL,
                      meta: VectorSetMeta,
                      documents: [String: [Float]],
                      queries: [String: [Float]]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var documentData = Data()
        for id in meta.documentIDs {
            guard let vector = documents[id] else {
                throw VectorError.missing("document vector for \(id)")
            }
            documentData.append(SemanticVector.encodeFloat16(vector))
        }
        var queryData = Data()
        for id in meta.queryIDs {
            guard let vector = queries[id] else {
                throw VectorError.missing("query vector for \(id)")
            }
            queryData.append(SemanticVector.encodeFloat16(vector))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: directory.appendingPathComponent("meta.json"))
        try documentData.write(to: directory.appendingPathComponent("documents.f16"))
        try queryData.write(to: directory.appendingPathComponent("queries.f16"))
    }

    static func read(directory: URL) throws -> VectorSet {
        let meta = try JSONDecoder().decode(
            VectorSetMeta.self,
            from: Data(contentsOf: directory.appendingPathComponent("meta.json"))
        )
        let documents = try split(
            Data(contentsOf: directory.appendingPathComponent("documents.f16")),
            ids: meta.documentIDs,
            dimensions: meta.storedDimensions
        )
        let queries = try split(
            Data(contentsOf: directory.appendingPathComponent("queries.f16")),
            ids: meta.queryIDs,
            dimensions: meta.storedDimensions
        )
        return VectorSet(meta: meta, documents: documents, queries: queries)
    }

    private static func split(_ data: Data, ids: [String], dimensions: Int) throws -> [String: [Float]] {
        let stride = dimensions * 2
        guard data.count == ids.count * stride else {
            throw VectorError.malformed(
                "expected \(ids.count) × \(dimensions) Float16 values (\(ids.count * stride) bytes), got \(data.count)"
            )
        }
        var result: [String: [Float]] = [:]
        for (index, id) in ids.enumerated() {
            let start = data.startIndex + index * stride
            let slice = data[start..<(start + stride)]
            guard let vector = SemanticVector.decodeFloat16(Data(slice)) else {
                throw VectorError.malformed("undecodable Float16 block for \(id)")
            }
            result[id] = vector
        }
        return result
    }
}

enum VectorError: LocalizedError {
    case missing(String)
    case malformed(String)
    case tooling(String)

    var errorDescription: String? {
        switch self {
        case let .missing(what): return "The vectors set is incomplete: \(what)."
        case let .malformed(what): return "The vectors set is malformed: \(what)."
        case let .tooling(what): return what
        }
    }
}

/// `docId#chunkIndex` — the chunk-level identity the store keys vectors on.
func chunkID(_ documentID: String, _ index: Int) -> String { "\(documentID)#\(index)" }

func sourceID(ofChunk chunk: String) -> String {
    String(chunk.split(separator: "#").dropLast().joined(separator: "#"))
}
