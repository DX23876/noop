import Foundation

/// A JSON value carried through decoding and encoding untouched, for fields this build does not know.
///
/// Stored records outlive the build that wrote them: a newer build adds a field, the wearer installs an
/// older one, and that older build re-encodes the record on its next save. Synthesized `Codable` drops
/// every key it has no property for, so the newer build's data would be gone by the time it is installed
/// again. Keeping the unknown keys as `PreservedJSON` and writing them back makes that round trip lossless.
enum PreservedJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PreservedJSON])
    case object([String: PreservedJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Bool before Double: the decoder refuses a number where a Bool is asked for, so the order only
        // matters for readability, but it keeps `true` from ever being read as 1.
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([PreservedJSON].self) {
            self = .array(value)
        } else {
            self = .object(try c.decode([String: PreservedJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

/// A coding key for any string, used to read and write keys a type has no `CodingKeys` case for.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
