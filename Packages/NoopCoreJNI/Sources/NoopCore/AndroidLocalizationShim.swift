import Foundation

/// The wearer's language for text the shared code writes itself (a goal's reason, a Momentum line), read from the
/// Apple String Catalog the Android build ships per language (`core-l10n/<language>.json`, generated from
/// `Localizable.xcstrings`). Empty, every text stays the English source, as before.
public enum CoreLocalization {
    nonisolated(unsafe) private static var table: [String: String] = [:]
    private static let lock = NSLock()

    /// Loads one language's table (`{"source key": "translation"}`); nil or an unreadable file clears it.
    public static func load(_ url: URL?) {
        let decoded = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        lock.lock(); table = decoded; lock.unlock()
    }

    static func lookup(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return table[key]
    }

    /// Fills a catalog format the way `String(localized:)` does on Apple: `%lld`, `%llu`, `%lf`, `%f`, `%d` and
    /// `%@`, in order or by position (`%2$@`), and `%%`. Written out rather than handed to `String(format:)`,
    /// which on Android has no bridge for a Swift `String` behind `%@`.
    static func format(_ format: String, _ args: [AndroidLocalizedString.Argument]) -> String {
        var out = ""
        var next = 0
        var i = format.startIndex
        while i < format.endIndex {
            let c = format[i]
            guard c == "%" else { out.append(c); i = format.index(after: i); continue }
            var j = format.index(after: i)
            guard j < format.endIndex else { out.append(c); break }
            if format[j] == "%" { out.append("%"); i = format.index(after: j); continue }
            var position: Int?
            var digits = ""
            var k = j
            while k < format.endIndex, format[k].isNumber { digits.append(format[k]); k = format.index(after: k) }
            if !digits.isEmpty, k < format.endIndex, format[k] == "$" {
                position = Int(digits).map { $0 - 1 }
                j = format.index(after: k)
            }
            // Flags, width, precision and length modifiers up to the conversion character.
            var spec = ""
            while j < format.endIndex {
                let ch = format[j]
                spec.append(ch)
                if "@dfiuxs".contains(ch) || spec.count > 8 { break }
                j = format.index(after: j)
            }
            guard j < format.endIndex else { out += String(format[i...]); break }
            let index = position ?? next
            if position == nil { next += 1 }
            out += index < args.count ? args[index].text(spec) : ""
            i = format.index(after: j)
        }
        return out
    }
}

/// A localizable text with its interpolated values, built by the compiler from `String(localized: "…\(x)…")` the
/// way Apple's `String.LocalizationValue` is: the catalog key carries `%lld` for an integer, `%lf` for a `Double`
/// and `%@` for everything else, so the same key finds the same translation on both platforms.
public struct AndroidLocalizedString: ExpressibleByStringInterpolation {
    public enum Argument {
        case int(Int64), uint(UInt64), double(Double), text(String)

        func text(_ spec: String) -> String {
            switch self {
            case .int(let v): return String(v)
            case .uint(let v): return String(v)
            case .double(let v):
                // A catalog format with a precision ("%.1f") keeps it; a bare "%lf" prints as Apple does.
                let precision = spec.split(separator: ".").dropFirst().first.flatMap { Int($0.filter(\.isNumber)) }
                return precision.map { String(format: "%.\($0)f", v) } ?? String(format: "%f", v)
            case .text(let s): return s
            }
        }
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var plain = ""
        var args: [Argument] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
            plain += literal
        }

        private mutating func add(_ spec: String, _ arg: Argument, _ shown: String) {
            key += spec; plain += shown; args.append(arg)
        }

        public mutating func appendInterpolation<T: BinaryInteger & SignedInteger>(_ value: T) {
            add("%lld", .int(Int64(value)), String(value))
        }
        public mutating func appendInterpolation<T: BinaryInteger & UnsignedInteger>(_ value: T) {
            add("%llu", .uint(UInt64(value)), String(value))
        }
        public mutating func appendInterpolation(_ value: Double) {
            add("%lf", .double(value), String(format: "%f", value))
        }
        public mutating func appendInterpolation(_ value: Float) {
            add("%f", .double(Double(value)), String(format: "%f", value))
        }
        public mutating func appendInterpolation(_ value: Double, specifier: String) {
            add(specifier, .double(value), String(format: specifier, value))
        }
        public mutating func appendInterpolation(_ value: String) {
            add("%@", .text(value), value)
        }
        public mutating func appendInterpolation(_ value: Substring) {
            add("%@", .text(String(value)), String(value))
        }
        public mutating func appendInterpolation<T>(_ value: T) {
            let shown = String(describing: value)
            add("%@", .text(shown), shown)
        }
    }

    let key: String
    let plain: String
    let args: [Argument]

    public init(stringLiteral value: String) {
        key = value; plain = value; args = []
    }

    public init(stringInterpolation: StringInterpolation) {
        // Without values the key is the literal itself, as Apple keeps it ("80 %" stays "80 %").
        key = stringInterpolation.args.isEmpty ? stringInterpolation.plain : stringInterpolation.key
        plain = stringInterpolation.plain
        args = stringInterpolation.args
    }

    var resolved: String {
        guard let translation = CoreLocalization.lookup(key) else { return plain }
        return args.isEmpty ? translation : CoreLocalization.format(translation, args)
    }
}

#if os(Android)
extension String {
    init(localized value: AndroidLocalizedString, comment: StaticString? = nil) { self = value.resolved }
    init(localized value: AndroidLocalizedString, defaultValue: AndroidLocalizedString, comment: StaticString? = nil) {
        self = CoreLocalization.lookup(value.key) != nil ? value.resolved : defaultValue.resolved
    }
}
#endif
