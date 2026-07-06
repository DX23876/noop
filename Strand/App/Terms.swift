import Foundation

/// The Terms of Use the first-run gate presents. Bump `currentVersion` when the terms MATERIALLY
/// change (risk / liability / medical / affiliation wording) to re-prompt every user for a fresh
/// acknowledgment; leave it for typo fixes. Mirrored on Android by `NoopPrefs.TERMS_VERSION`. The
/// full text lives in `TERMS.md`, shipped with NOOP.
enum Terms {
    static let currentVersion = "2.0"

    /// The load-bearing points the user must accept on first launch — the plain-English summary of
    /// `TERMS.md` §1–§6. Kept identical to the Android `Terms.points`. Each is (headline, body).
    /// Wrapped in `String(localized:)` (the `RhythmView.points` pattern) so the gate is localized
    /// like the rest of the app (PR #984); the English wording is the key, and the binding text
    /// stays `TERMS.md` — a translation here is a courtesy, not the agreement.
    static let points: [(String, String)] = [
        (String(localized: "Independent: not affiliated with WHOOP"),
         String(localized: "NOOP is an unofficial project: not affiliated with, endorsed by, or sponsored by WHOOP, Inc. \"WHOOP\" is their trademark, used only to name the hardware NOOP works with.")),
        (String(localized: "Using NOOP may breach WHOOP's Terms of Service"),
         String(localized: "Use it only with a device you own, to read your own data. Whether to use it (and any effect on your WHOOP account, subscription, device, or warranty) is your decision, and your risk alone.")),
        (String(localized: "Experimental: at your own risk"),
         String(localized: "NOOP talks to your strap's firmware over an unofficial, independently-mapped protocol. There is a residual risk to the device, its data, and its connection to official services. You assume that risk.")),
        (String(localized: "Not a medical device, not medical advice"),
         String(localized: "Every metric is an unvalidated approximation. Don't use NOOP to diagnose, treat, or make any health decision. Always consult a qualified professional.")),
        (String(localized: "No warranty; liability limited"),
         String(localized: "NOOP is free and provided \"as is\", with no warranty. Liability is limited to the maximum extent the law that applies to you allows, and nothing here removes protections your local law won't let us remove.")),
    ]

    /// The affirmative attestations the user must EACH tick before Accept enables (clickwrap). They are
    /// kept as separate, conspicuous consents rather than one blanket box so each is a distinct, knowing
    /// acknowledgment — the load-bearing ones being the non-affiliation attestation and the liability
    /// waiver. Mirrors the Android `Terms.attestations`. The English wording is the binding key (like
    /// `points`); `TERMS.md` is the full text.
    /// NOTE: the exact legal phrasing here should be reviewed by a solicitor before this ships publicly.
    static let attestations: [String] = [
        String(localized: "I am not a WHOOP employee, contractor, or affiliate, and I am not using NOOP on WHOOP's behalf."),
        String(localized: "I own the WHOOP device I will use with NOOP and will only use it to access my own data. Doing so is my decision and my risk, including any effect on my WHOOP account, subscription, device, or warranty, and it may breach WHOOP's Terms of Service."),
        String(localized: "I understand NOOP is unofficial and experimental, is provided free and \"as is\" with no warranty, and is not a medical device or medical advice."),
        String(localized: "To the fullest extent the law allows, I will not hold the NOOP project or its contributors liable for any loss or damage arising from my use of it."),
    ]
}
