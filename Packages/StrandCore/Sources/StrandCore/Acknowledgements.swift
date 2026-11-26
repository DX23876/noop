import Foundation

/// Who and what NOOP Forge credits, declared once for every platform.
///
/// The Acknowledgements screen of the Apple apps (`AcknowledgementsView`) and the Android one read this one list,
/// so the fork's credit rule holds on both from one place: when the fork adopts someone's work, they are added to
/// `contributors` below (and to `ATTRIBUTION.md`), and both platforms show them. Handles and summaries are not
/// translated, like the third-party entries. Keep the lists in step with `docs/fork/THIRD_PARTY_NOTICES.md`,
/// `NOTICE` and `ATTRIBUTION.md` by hand when a source is added, removed or its rights status changes.
public enum Acknowledgements {

    /// A person or project whose work was taken in directly: `handle` and a short `work` summary.
    public struct Contributor: Equatable, Sendable {
        public let handle: String
        public let work: String
        public init(handle: String, work: String) { self.handle = handle; self.work = work }
    }

    /// Third-party content used under its own licence: a title, what it is used for and an optional link.
    public struct Entry: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let link: String?
        public init(title: String, detail: String, link: String? = nil) {
            self.title = title; self.detail = detail; self.link = link
        }
    }

    /// A library, model or ported code whose licence asks for its text to travel with every copy. `resource` names
    /// the verbatim text (`<resource>.txt`) shipped with the app. `appleOnly` marks what only the Apple apps contain,
    /// so Android never claims a dependency it does not have.
    public struct BundledLicense: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let link: String
        public let licenseName: String
        public let resource: String
        public let appleOnly: Bool
        public init(title: String, detail: String, link: String, licenseName: String, resource: String,
                    appleOnly: Bool = false) {
            self.title = title; self.detail = detail; self.link = link
            self.licenseName = licenseName; self.resource = resource; self.appleOnly = appleOnly
        }
        /// "MIT · GRDB-LICENSE.txt": the licence and the bundled file, never translated.
        public var fileLabel: String { licenseName + " · " + resource + ".txt" }
    }

    /// Where the full list of adopted work, with sources, is kept.
    public static let attributionURL = "https://github.com/DX23876/noop/blob/main/ATTRIBUTION.md"

    /// The content entries that come before the exercise provider's own credit line.
    public static let contentEntries: [Entry] = [
        Entry(title: "MuscleMap body geometry",
              detail: "Used for the Exercise Library's muscle picker. melihcolpan / repository contributors, MIT licence.",
              link: "https://github.com/melihcolpan/MuscleMap"),
        Entry(title: "react-native-body-highlighter body geometry",
              detail: "Used for the Strength screen's muscle load map. Copyright (c) 2022 ELABBASSI Hicham, MIT licence.",
              link: "https://github.com/HichamELBSI/react-native-body-highlighter"),
        Entry(title: "ExerciseDB v1 exercise data",
              detail: "Exercise names, body parts, equipment, targets, muscle groups and instructions via hasaneyldrm/exercises-dataset. MIT licence.",
              link: "https://github.com/hasaneyldrm/exercises-dataset"),
    ]

    /// The note on exercise media, which comes after the licences.
    public static let mediaEntry = Entry(
        title: "Exercise media (images and animations)",
        detail: "© Gym visual — gymvisual.com. Not licensed to NOOP: cloning the exercises-dataset repository is not a licence to its media. NOOP never bundles these files; downloading them is an explicit, disclosed, opt-in action, and the credit line appears under every animation.")

    /// The people credited in ATTRIBUTION.md ("NOOP Forge: work adopted from other people"). Add to it when the fork
    /// adopts someone's work.
    public static let contributors: [Contributor] = [
        Contributor(handle: "@UtkuDenizAltiok", work: "Deleted-nights list, sync reminder, SDNN guard, wind-down sleep need, skin temperature once and in your unit, translations"),
        Contributor(handle: "@ayiskakov", work: "Offload data-loss fixes, Bluetooth power-off teardown, deep-sleep onset hold, delete versus re-score, trained sleep-stage model (Lab)"),
        Contributor(handle: "@kavemang", work: "Sleep marks through Shortcuts, DST tests, gravity witness, workout edits shown before the rescore"),
        Contributor(handle: "@Iskrata", work: "Absolute skin temperature on import, beat-to-beat intervals and nightly vitals in Apple Health"),
        Contributor(handle: "@gdorgian", work: "Liquid clocks stand down when still, a short last sleep stretch is kept"),
        Contributor(handle: "@mohamedchnafy-ds", work: "Weekly sets per muscle (idea), recent naps for the coach"),
        Contributor(handle: "@JohanStefanes", work: "5/MG one-shot buzz without RUN_ALARM"),
        Contributor(handle: "@christophersarmiento", work: "Strap model stamped only after a scan accepts it"),
        Contributor(handle: "@goodgord", work: "No sleep merge across a data gap"),
        Contributor(handle: "@spidervirus", work: "No startup zero heart rate"),
        Contributor(handle: "@rome6", work: "One guarded runner for the Health Connect import, with a named outcome"),
        Contributor(handle: "@fadkeprasad", work: "Power-saving cadence for automatic syncs"),
        Contributor(handle: "@paradix86", work: "Italian WHOOP exports"),
        Contributor(handle: "@msff", work: "Mac menu-bar redraws"),
        Contributor(handle: "@andynilson", work: "Charge and Effort translations"),
        Contributor(handle: "@shajidahmed", work: "Config read-back check"),
        Contributor(handle: "@abhilashvadnala", work: "Day cycle on an early bedtime"),
        Contributor(handle: "@reinmaker", work: "Split-night consistency"),
        Contributor(handle: "@Billytheking954", work: "Restore rollback through the WAL"),
        Contributor(handle: "@J-Gur", work: "Health Connect permissions"),
        Contributor(handle: "@rntcruz23", work: "Connect failure message"),
        Contributor(handle: "@bartmuskala", work: "Maximum heart rate resolver"),
        Contributor(handle: "bogaczcyprien-svg, aansun, denismanulov", work: "Respiratory-rate grid, off-wrist sleep cut, an offload data-loss path"),
        Contributor(handle: "Pilleus", work: "German wording corrected across both catalogues"),
        Contributor(handle: "meta1971, OpenStrap", work: "5/MG SET_CLOCK sub-seconds, MG ECG reading"),
    ]

    /// Libraries, models and ported code inside the app whose licence asks for its text to travel with every copy.
    /// Each text ships verbatim with the app (`Strand/Resources/ThirdParty/`; the Android build packs the same
    /// folder as assets) and opens from its row.
    public static let bundledLicenses: [BundledLicense] = [
        BundledLicense(title: "GRDB.swift", detail: "SQLite database layer. Copyright (C) 2015-2024 Gwendal Roué.",
                       link: "https://github.com/groue/GRDB.swift", licenseName: "MIT", resource: "GRDB-LICENSE"),
        BundledLicense(title: "ZIPFoundation", detail: "Reads export archives during import. Copyright (c) 2017-2025 Thomas Zoechling.",
                       link: "https://github.com/weichsel/ZIPFoundation", licenseName: "MIT", resource: "ZIPFoundation-LICENSE"),
        BundledLicense(title: "MarkdownUI", detail: "Renders the coach's replies. Copyright (c) 2020 Guillermo Gonzalez.",
                       link: "https://github.com/gonzalezreal/swift-markdown-ui", licenseName: "MIT", resource: "MarkdownUI-LICENSE",
                       appleOnly: true),
        BundledLicense(title: "Swift Crypto", detail: "Cryptographic primitives. Copyright Apple Inc. and the Swift project authors.",
                       link: "https://github.com/apple/swift-crypto", licenseName: "Apache 2.0", resource: "SwiftCrypto-LICENSE"),
        BundledLicense(title: "llama.cpp", detail: "On-device inference for the coach's memory index (iPhone). Copyright (c) 2023-2026 The ggml authors.",
                       link: "https://github.com/ggml-org/llama.cpp", licenseName: "MIT", resource: "llama.cpp-LICENSE",
                       appleOnly: true),
        BundledLicense(title: "nomic-embed-text-v2-moe", detail: "On-device text embedding model for the coach's memory index (iPhone). Nomic AI.",
                       link: "https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe", licenseName: "Apache 2.0",
                       resource: "nomic-embed-text-v2-moe-LICENSE", appleOnly: true),
        BundledLicense(title: "OpenStrap", detail: "The WHOOP MG ECG reading flow, ported from release v0.10.0. Copyright (c) 2026 OpenStrap.",
                       link: "https://github.com/OpenStrap/edge", licenseName: "MIT", resource: "OpenStrap-LICENSE"),
    ]
}
