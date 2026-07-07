import Foundation

/// Single source of truth for project identity and attribution. Deliberately
/// contains no author/AI identifiers so the public repo can stay anonymous.
enum ProjectInfo {
    static let appName = "NOOP"
    static let tagline = "Your strap. Your data. Your machine. Local-first, no cloud."
    static let version = "0.1.0"
    /// Public contact for questions, feedback, bug reports. Baked into every platform.
    static let contactEmail = "thenoopapp@gmail.com"

    /// Open-source reverse-engineering this is built on.
    static let attributions: [(repo: String, note: String)] = [
        ("johnmiddleton12/my-whoop", "WHOOP 4.0 BLE protocol"),
        ("b-nnett/goose", "WHOOP 5.0 BLE protocol"),
    ]
}
