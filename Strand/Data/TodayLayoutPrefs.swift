import Foundation
import SwiftUI

// MARK: - Reorderable Today sections (#today-layout)
//
// The liquid Today's sections — the Charge/Effort/Rest hero, the Start-session entry, Synthesis, Key
// Metrics, Workouts, Heart Rate, Recovery Vitals, Your Cards — rendered in one fixed order. This lets the
// user REORDER them, with the default being the original order so nothing changes for anyone who never
// rearranges. Display-only — no metric is computed or stored differently; this only decides the SEQUENCE
// the already-built sections render in.
//
// Stored as a single comma-joined string of section keys in @AppStorage("today.sectionOrder"), the same
// mechanism KeyMetricPrefs uses. The Android side mirrors this byte-identically in TodayLayoutPrefs.kt
// (SharedPreferences "today.sectionOrder"). Every known section ALWAYS renders: unknown tokens are dropped,
// and any known section missing from the saved order is INSERTED at its default-order position relative to
// the saved sections — so a section added in a later version surfaces where users expect it rather than
// teleporting to the bottom of an existing saved order. This reorders, it never hides.

/// One reorderable Today section. The rawValue is the stable persisted identifier — keep it byte-identical
/// to the Android `TodaySection` enum so a backup/restore reads the same layout on either OS.
enum TodaySection: String, CaseIterable, Identifiable {
    case hero
    case liveSession
    case synthesis
    case keyMetrics
    case workouts
    case heartRate
    case recoveryVitals
    case yourCards
    case journal
    case dataSources

    var id: String { rawValue }

    /// The section's display label in the Arrange sheet — matches the Android `TodaySection.title`.
    var title: String {
        switch self {
        case .hero:           return String(localized: "Charge / Effort / Rest")
        case .liveSession:    return String(localized: "Start session")
        case .synthesis:      return String(localized: "Synthesis")
        case .keyMetrics:     return String(localized: "Key Metrics")
        case .workouts:       return String(localized: "Workouts")
        case .heartRate:      return String(localized: "Heart Rate")
        case .recoveryVitals: return String(localized: "Recovery Vitals")
        case .yourCards:      return String(localized: "Your Cards")
        case .journal:        return String(localized: "Journal")
        case .dataSources:    return String(localized: "Data Sources")
        }
    }

    /// The original, hard-coded section order — the default when the layout isn't customised. The journal
    /// widget (#656) sits above the data-sources card, which is last.
    static let defaultOrder: [TodaySection] = [
        .hero, .liveSession, .synthesis, .keyMetrics, .workouts, .heartRate, .recoveryVitals, .yourCards,
        .journal, .dataSources,
    ]

    /// Sections hidden by default on a new/never-customised install: none. The redesign originally
    /// decluttered Heart Rate, Recovery Vitals, Your Cards and Data Sources off the home screen by default;
    /// that default was reverted (product decision) so a fresh install shows every section, matching the
    /// classic Today. Not a removal of the feature — the Arrange sheet still lets a user hide any section,
    /// and the stored `today.hiddenSections` string remains authoritative once set (an empty string = nothing
    /// hidden, same as this default), so existing users who already hid sections keep that choice untouched.
    static let defaultHidden: Set<TodaySection> = []

    /// UX hierarchy: "major" sections (the hero scores, the Synthesis verdict, the Key Metrics grid, and
    /// the Recovery Vitals) carry more visual weight and get extra breathing room above them, while minor
    /// sections (workouts, HR, journal, data sources) sit tighter. This drives the graduated spacing in
    /// LiquidTodayView's section stack so the screen reads in clear groups instead of a uniform dense list.
    var isMajorSection: Bool {
        switch self {
        case .hero, .synthesis, .keyMetrics, .recoveryVitals: return true
        default: return false
        }
    }
}

/// Display-only persistence for the Today section order. Holds the sections in display order; every known
/// section always renders (a missing one is inserted at its default position), so this reorders but never
/// hides. Mirrors the Android `TodayLayoutPrefs` (SharedPreferences "today.sectionOrder") byte-for-byte.
enum TodayLayoutPrefs {
    /// UserDefaults key — a comma-joined list of `TodaySection` rawValues in display order.
    static let orderKey = "today.sectionOrder"

    /// UserDefaults key — a comma-joined list of `TodaySection` rawValues that are HIDDEN (§4). Its
    /// @AppStorage default is `encodeHidden(TodaySection.defaultHidden)`, so an unset install hides the
    /// redesign's decluttered set; an explicit empty string means "show everything".
    static let hiddenKey = "today.hiddenSections"

    /// Encode a hidden set into the stored string, in `allCases` order so it's deterministic.
    static func encodeHidden(_ hidden: Set<TodaySection>) -> String {
        TodaySection.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }

    /// Decode the stored hidden string into a set (unknown tokens dropped). An empty string = nothing hidden.
    static func decodeHidden(_ raw: String) -> Set<TodaySection> {
        Set(raw.split(separator: ",").compactMap {
            TodaySection(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
    }

    /// Encode an ordered section list into the stored comma-joined string.
    static func encode(_ sections: [TodaySection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Decode the stored string into the FULL ordered section list. An empty/unset string yields the
    /// default order. Unknown tokens are ignored, duplicates collapsed, and any known section missing from
    /// the saved order is INSERTED at its default-order position relative to the saved sections (before the
    /// first saved section that follows it in the default order; appended when none does) — so every
    /// section always renders, and one added in a later app version surfaces where users expect it instead
    /// of teleporting to the bottom of an existing saved order. Twin of the Kotlin `decodeOrder`.
    static func decodeOrder(_ raw: String) -> [TodaySection] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return TodaySection.defaultOrder }
        var saved: [TodaySection] = []
        for token in trimmed.split(separator: ",") {
            if let s = TodaySection(rawValue: token.trimmingCharacters(in: .whitespaces)), !saved.contains(s) {
                saved.append(s)
            }
        }
        guard !saved.isEmpty else { return TodaySection.defaultOrder }
        // Iterate allCases (not defaultOrder) so a future case accidentally left out of defaultOrder can
        // never be silently hidden; a section without a default index sorts after everything (no crash —
        // the Kotlin twin's indexOf(-1) degrades the same way). defaultOrder covering allCases is pinned
        // by TodayLayoutPrefsTests on both platforms.
        func defIdx(_ s: TodaySection) -> Int {
            TodaySection.defaultOrder.firstIndex(of: s) ?? TodaySection.defaultOrder.count
        }
        for missing in TodaySection.allCases where !saved.contains(missing) {
            let insertAt = saved.firstIndex { defIdx($0) > defIdx(missing) }
            if let insertAt { saved.insert(missing, at: insertAt) } else { saved.append(missing) }
        }
        return saved
    }
}
