import Foundation

/// Model-independent constants that both the iOS adapter and deterministic tests use. Keeping the
/// asymmetric retrieval prefixes here prevents a provider refactor from silently indexing documents
/// and queries in the wrong Nomic task space.
public enum NomicEmbeddingContract {
    public static let outputDimensions = 256
    public static let maximumInputTokens = 384
    public static let modelMaximumTokens = 512
    public static let documentPrefix = "search_document: "
    public static let queryPrefix = "search_query: "

    public static func documentText(_ text: String) -> String { documentPrefix + text }
    public static func queryText(_ text: String) -> String { queryPrefix + text }
}

public enum SemanticSourceKind: String, Codable, CaseIterable, Sendable {
    case memoryFact
    case conversationTitle
    case conversationSummary
    case userMessage
    case journalQuestion
    case journalNote
    case recommendationFeedback
    case habitHypothesis
}

public enum SemanticConsentScope: String, Codable, CaseIterable, Sendable {
    case memory
    case personalLogs
    case sensitiveLogs
    case patterns
}

public struct SemanticDocument: Equatable, Sendable {
    public let sourceKind: SemanticSourceKind
    public let sourceID: String
    public let chunkIndex: Int
    public let text: String
    public let updatedAt: Date
    public let consentScope: SemanticConsentScope
    public let priority: Int

    public init(sourceKind: SemanticSourceKind,
                sourceID: String,
                chunkIndex: Int = 0,
                text: String,
                updatedAt: Date,
                consentScope: SemanticConsentScope,
                priority: Int = 0) {
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.chunkIndex = chunkIndex
        self.text = text
        self.updatedAt = updatedAt
        self.consentScope = consentScope
        self.priority = priority
    }

    public var documentID: String {
        "\(sourceKind.rawValue):\(sourceID):\(chunkIndex)"
    }

    public var contentHash: String {
        SemanticHash.fnv1a64Hex(text)
    }
}

public struct SemanticHit: Equatable, Sendable {
    public let documentID: String
    public let sourceKind: SemanticSourceKind
    public let sourceID: String
    public let chunkIndex: Int
    public let score: Double
    public let consentScope: SemanticConsentScope

    public init(documentID: String,
                sourceKind: SemanticSourceKind,
                sourceID: String,
                chunkIndex: Int,
                score: Double,
                consentScope: SemanticConsentScope) {
        self.documentID = documentID
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.chunkIndex = chunkIndex
        self.score = score
        self.consentScope = consentScope
    }
}

public struct SemanticIndexStatus: Equatable, Sendable {
    public let modelID: String
    public let indexedDocuments: Int
    public let pendingDocuments: Int
    public let byteSize: Int64
    public let lastRunAt: Date?
    public let lastError: String?
    public let isModelLoaded: Bool

    public init(modelID: String,
                indexedDocuments: Int,
                pendingDocuments: Int,
                byteSize: Int64,
                lastRunAt: Date?,
                lastError: String?,
                isModelLoaded: Bool) {
        self.modelID = modelID
        self.indexedDocuments = indexedDocuments
        self.pendingDocuments = pendingDocuments
        self.byteSize = byteSize
        self.lastRunAt = lastRunAt
        self.lastError = lastError
        self.isModelLoaded = isModelLoaded
    }

    public var totalDocuments: Int {
        indexedDocuments + pendingDocuments
    }

    /// Rebuildable indexing progress for UI surfaces. An empty index has no work left and therefore
    /// reports completion rather than showing an indeterminate zero-percent state forever.
    public var completionFraction: Double {
        guard totalDocuments > 0 else { return 1 }
        return min(1, max(0, Double(indexedDocuments) / Double(totalDocuments)))
    }

    public var completionPercentage: Int {
        Int((completionFraction * 100).rounded(.down))
    }
}

public protocol TextEmbeddingProvider: AnyObject, Sendable {
    var modelID: String { get }
    var dimensions: Int { get }
    func prepare() async throws
    func embedDocuments(_ texts: [String]) async throws -> [[Float]]
    func embedQuery(_ text: String) async throws -> [Float]
    func unload() async
}

/// Platform-neutral orchestration boundary. Apple currently supplies the first implementation; Android
/// can adopt the same document/scope/status contract without sharing its runtime implementation.
@MainActor
public protocol SemanticMemoryCoordinator: AnyObject {
    var semanticIndexStatus: SemanticIndexStatus { get }
    func enqueueSemanticDocuments(_ documents: [SemanticDocument]) async
    func purgeSemanticScopes(_ scopes: Set<SemanticConsentScope>) async
}

public enum SemanticMemoryError: LocalizedError, Equatable {
    case invalidDimensions(expected: Int, actual: Int)
    case invalidVector
    case modelUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidDimensions(expected, actual):
            return "Expected a \(expected)-dimensional embedding, received \(actual)."
        case .invalidVector:
            return "The embedding model returned an invalid vector."
        case let .modelUnavailable(reason):
            return reason
        }
    }
}

public enum SemanticHash {
    /// Platform-neutral FNV-1a over UTF-16 code units. Swift's `hashValue` is randomized and Kotlin's
    /// `hashCode` has different semantics, so neither may identify a cross-platform source revision.
    public static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for unit in text.utf16 {
            hash ^= UInt64(unit)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

public enum SemanticVector {
    public static func normalizedTruncated(_ values: [Float], dimensions: Int) throws -> [Float] {
        guard values.count >= dimensions else {
            throw SemanticMemoryError.invalidDimensions(expected: dimensions, actual: values.count)
        }
        let truncated = Array(values.prefix(dimensions))
        let squared = truncated.reduce(Float.zero) { $0 + ($1 * $1) }
        guard squared.isFinite, squared > 0 else { throw SemanticMemoryError.invalidVector }
        let norm = sqrt(squared)
        return truncated.map { $0 / norm }
    }

    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.infinity }
        var dot: Float = 0
        var leftNorm: Float = 0
        var rightNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftNorm += lhs[index] * lhs[index]
            rightNorm += rhs[index] * rhs[index]
        }
        guard leftNorm > 0, rightNorm > 0 else { return -.infinity }
        return Double(dot / sqrt(leftNorm * rightNorm))
    }

    /// IEEE-754 binary16 conversion done in integer arithmetic rather than through the `Float16` type.
    ///
    /// `Float16` is an **arm64-only** stdlib type on macOS — on the x86_64 slice it doesn't exist, so a
    /// universal build (`ARCHS="x86_64 arm64"`, which is how CI builds the macOS app, #51) fails to
    /// compile while a local arm64-thinned build succeeds. That asymmetry is the trap: the break is
    /// invisible on an Apple-Silicon dev machine and only ever shows up in CI.
    ///
    /// The conversion is round-to-nearest-even, exactly what the hardware instruction does, so the
    /// encoding stays **byte-identical to the `Float16` implementation this replaces** — already-indexed
    /// embedding vectors on disk remain valid and re-encode to the same bytes. `testFloat16MatchesHardware`
    /// pins that equivalence against real `Float16` wherever the type is available.
    static func binary16Bits(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16(truncatingIfNeeded: (bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF)
        let mantissa = bits & 0x007F_FFFF

        // Inf / NaN: keep a NaN a NaN (a payload truncated to zero would silently become Inf).
        if exponent == 0xFF {
            if mantissa == 0 { return sign | 0x7C00 }
            return sign | 0x7E00 | UInt16(truncatingIfNeeded: mantissa >> 13)
        }

        let halfExponent = exponent - 127 + 15
        if halfExponent >= 0x1F { return sign | 0x7C00 }        // overflows binary16's range → ±Inf

        if halfExponent <= 0 {
            // Subnormal binary16 (or an underflow to ±0): the value is k * 2^-24 for integer k, so shift
            // the 24-bit significand down by (126 - exponent) and round. A float32 subnormal or zero
            // (exponent == 0) lands in the same branch and underflows to ±0, as it must.
            let shift = 126 - exponent
            if shift > 24 { return sign }
            let significand = mantissa | 0x0080_0000
            let halfway: UInt32 = 1 << (shift - 1)
            let remainder = significand & ((1 << shift) - 1)
            var quantized = significand >> shift
            if remainder > halfway || (remainder == halfway && quantized & 1 == 1) { quantized += 1 }
            // A carry out of the subnormal range yields the smallest normal binary16 — the correct result.
            return sign | UInt16(truncatingIfNeeded: quantized)
        }

        let remainder = mantissa & 0x1FFF                        // the 13 bits binary16 cannot keep
        var quantized = mantissa >> 13
        if remainder > 0x1000 || (remainder == 0x1000 && quantized & 1 == 1) { quantized += 1 }
        // Added, not OR-ed: a mantissa carry must roll into the exponent (and may reach ±Inf, correctly).
        return sign | UInt16(truncatingIfNeeded: (UInt32(halfExponent) << 10) + quantized)
    }

    /// The inverse of `binary16Bits`, likewise free of `Float16` — see that method for why.
    static func float(fromBinary16 bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x03FF)

        if exponent == 0x1F {                                    // Inf / NaN
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        if exponent == 0 {
            if mantissa == 0 { return Float(bitPattern: sign) }  // ±0
            // Subnormal binary16 == mantissa * 2^-24, which is a perfectly ordinary (normal) float32,
            // so this scaling is exact — no second rounding.
            let magnitude = Float(mantissa) * 0x1p-24
            return sign == 0 ? magnitude : -magnitude
        }
        // 112 == 127 - 15: rebias the exponent, then pad the mantissa back out to 23 bits.
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }

    public static func encodeFloat16(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<UInt16>.size)
        for value in values {
            var littleEndian = binary16Bits(value).littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decodeFloat16(_ data: Data) -> [Float]? {
        guard data.count.isMultiple(of: MemoryLayout<UInt16>.size) else { return nil }
        var result: [Float] = []
        result.reserveCapacity(data.count / MemoryLayout<UInt16>.size)
        var index = data.startIndex
        while index < data.endIndex {
            let next = data.index(index, offsetBy: 2)
            let raw = data[index..<next].withUnsafeBytes { bytes in
                UInt16(littleEndian: bytes.loadUnaligned(as: UInt16.self))
            }
            result.append(float(fromBinary16: raw))
            index = next
        }
        return result
    }
}
