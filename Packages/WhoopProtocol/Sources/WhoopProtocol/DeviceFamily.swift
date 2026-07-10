import Foundation

/// Which Whoop hardware generation a connection / capture belongs to.
///
/// This package is platform-pure: it never imports CoreBluetooth. The app layer is responsible
/// for turning the UUID *strings* exposed here into `CBUUID` values. Keeping CBUUID out of this
/// module lets the protocol code run on any platform (and in CLI tools / tests) unchanged.
public enum DeviceFamily: String, Sendable, CaseIterable {
    /// Whoop 4.0 — 0x07 CRC8 header check.
    case whoop4
    /// Whoop 5.0 / MG — CRC16-Modbus header check, "puffin" packet types.
    case whoop5
}

/// Which checksum guards the frame header for a given device family.
public enum HeaderCRCKind: String, Sendable, CaseIterable {
    /// CRC8 (poly 0x07) over the two declared-length bytes — Whoop 4.0.
    case crc8
    /// CRC16-Modbus (poly 0xA001, init 0xFFFF, reflected) over the header prefix — Whoop 5.0.
    case crc16Modbus
}

public extension DeviceFamily {
    /// Resolve a device-registry `model` label to the strap family that wrote its rows (#171).
    ///
    /// The registry holds several historical spellings for the same hardware: the Add-Device wizard
    /// stores bare "4.0" / "5.0 MG", other paths match the full picker labels ("WHOOP 4.0" /
    /// "WHOOP 5.0 / MG"), and the legacy seeded "my-whoop" row stores just "WHOOP". Matching any
    /// single spelling silently misses the others (#171), so this is the ONE place allowed to
    /// interpret registry model labels.
    ///
    /// "WHOOP" predates the wizard and was written identically for 4.0 and 5/MG installs, so it
    /// carries no family information; it keeps the prior `.whoop5` fallback, as do nil/unknown
    /// labels (non-WHOOP imports whose skin temp is already °C) — only a positively-identified 4.0
    /// changes scale (#938). Mirrors the Kotlin `DeviceFamily.forRegistryModel`.
    static func forRegistryModel(_ model: String?) -> DeviceFamily {
        switch model {
        case "4.0", "WHOOP 4.0": return .whoop4
        default: return .whoop5
        }
    }

    /// The header-CRC algorithm this family uses. This is the single switch that the family-aware
    /// `verifyFrame`/`parseFrame` overloads branch on; the payload CRC32 is identical for both.
    var headerCRCKind: HeaderCRCKind {
        switch self {
        case .whoop4: return .crc8
        case .whoop5: return .crc16Modbus
        }
    }

    /// Primary GATT service UUID *string* for this family (lowercase, as advertised).
    /// The app layer wraps this in `CBUUID(string:)`.
    var serviceUUIDString: String {
        switch self {
        case .whoop4: return "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .whoop5: return "fd4b0001-cce1-4033-93ce-002d5875f58a"
        }
    }

    /// Characteristic UUID *strings* this family uses, in stable ascending order.
    ///
    /// Whoop 4.0 exposes 0002…0005 under the 6108 service. Whoop 5.0 adds an extra 0007
    /// characteristic under the fd4b service. These are plain strings (no CBUUID) on purpose.
    var characteristicUUIDStrings: [String] {
        switch self {
        case .whoop4:
            return [
                "61080002-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
            ]
        case .whoop5:
            return [
                "fd4b0002-cce1-4033-93ce-002d5875f58a",
                "fd4b0003-cce1-4033-93ce-002d5875f58a",
                "fd4b0004-cce1-4033-93ce-002d5875f58a",
                "fd4b0005-cce1-4033-93ce-002d5875f58a",
                "fd4b0007-cce1-4033-93ce-002d5875f58a",
            ]
        }
    }

    /// The command/write characteristic UUID *string* for this family (the …0002 endpoint that
    /// CLIENT_HELLO and command frames are written to).
    var commandCharacteristicUUIDString: String {
        switch self {
        case .whoop4: return "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .whoop5: return "fd4b0002-cce1-4033-93ce-002d5875f58a"
        }
    }

    /// Static CLIENT_HELLO frame this family writes immediately after GATT discovery to start a
    /// session. `nil` for families that do not use a fixed hello.
    ///
    /// The Whoop 5.0 hello is a fully-formed type-35 (COMMAND) frame with CRC16-Modbus header and
    /// CRC32 payload trailer. Transcribed verbatim from the Goose reverse-engineering
    /// (`GooseHello.clientHelloFrameHex` = "aa0108000001e67123019101363e5c8d").
    var clientHello: [UInt8]? {
        switch self {
        case .whoop4:
            return nil
        case .whoop5:
            return DeviceFamily.whoop5ClientHello
        }
    }

    /// Whoop 5.0 CLIENT_HELLO bytes (16 bytes). Exposed as a named constant for test/debug use.
    static let whoop5ClientHello: [UInt8] = [
        0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
        0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D,
    ]
}

// MARK: - Puffin packet type names

/// Whoop 5.0 introduces "puffin" packet types that mirror existing 4.0 types but on the new
/// transport. These map onto the canonical base type names so they decode like their 4.0
/// counterparts instead of falling through to an "unknown"/"typeN" label.
public enum PuffinPacketType {
    /// Puffin command response — behaves like COMMAND_RESPONSE (type 36).
    public static let puffinCommandResponse: Int = 38
    /// Puffin metadata — behaves like METADATA (type 49).
    public static let puffinMetadata: Int = 56
}

/// Canonical type name for a packet type byte, aliasing the Whoop 5.0 "puffin" types onto the
/// base names they share decoding semantics with:
/// - 38 (PUFFIN_COMMAND_RESPONSE) → "COMMAND_RESPONSE"
/// - 56 (PUFFIN_METADATA)         → "METADATA"
///
/// For every other type this defers to the schema's own `typeName`, so existing behaviour is
/// unchanged. This guarantees the puffin types never decode as "unknown" even if the schema's
/// PacketType enum lacks them.
public func canonicalTypeName(_ t: Int, schema: Schema) -> String {
    switch t {
    case PuffinPacketType.puffinCommandResponse: return "COMMAND_RESPONSE"
    case PuffinPacketType.puffinMetadata: return "METADATA"
    default: return schema.typeName(t)
    }
}
