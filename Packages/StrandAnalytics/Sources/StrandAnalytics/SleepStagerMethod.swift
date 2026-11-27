import Foundation
import WhoopProtocol

extension SleepStager {
    /// The complete detection and staging pipeline. V3 keeps V2 phases and establishes onset before
    /// allowing the continuity bridge to absorb leading rest; V1 and V2 retain the original detector.
    public enum Method: String, Codable, CaseIterable, Sendable {
        case v1, v2, v3

        public var usesV2Stages: Bool { self != .v1 }

        /// Product preference migration, separate from the legacy Boolean analytics API. An explicit
        /// classic choice survives; the former default upgrades to V3. A new explicit V2 stays V2.
        public static func resolvedPreference(rawValue: String?, legacyV2: Bool?) -> Method {
            if let rawValue, let method = Method(rawValue: rawValue) { return method }
            return legacyV2 == false ? .v1 : .v3
        }
    }
}

extension SleepStager {
    /// Which recipe stages the epochs of an accepted night under a V2-family `Method` (V2 or V3); V1 keeps its own
    /// stager whatever this says. A Lab choice that defaults to `.standard`, so a wearer who never touches it
    /// stages exactly as before. Stored as its raw value (`noopSleepStagingRecipe`, backup `sleep.stagingRecipe`).
    public enum StagingRecipe: String, Codable, CaseIterable, Sendable {
        /// `SleepStagerV2`, the hand-built recipe.
        case standard
        /// `SleepStagerV2` with `RestlessTerm.remOnly`: sustained small movements count against REM (#59, Lab only).
        case restless
        /// `SleepStagerTrained`, ayiskakov's model fitted to open polysomnography (Lab only).
        case trained

        /// What a stored signature appends for this recipe: nothing for `.standard`, so a signature written before
        /// the recipe existed still matches; "+<raw value>" otherwise, so a switch re-keys every day and every
        /// edited night. The day cache and the edit heal both read it here.
        public var signatureSuffix: String { self == .standard ? "" : "+\(rawValue)" }

        /// An unknown or missing stored value is the standard recipe, never a guess.
        public static func resolved(rawValue: String?) -> StagingRecipe {
            rawValue.flatMap(StagingRecipe.init(rawValue:)) ?? .standard
        }
    }

    /// The one place a V2-family night is staged: every caller that used to call `SleepStagerV2.stageSession`
    /// stages through here, so a recipe choice cannot reach detection and miss the edit heal, or the reverse.
    public static func stageV2Family(_ recipe: StagingRecipe, start: Int, end: Int, grav: [GravitySample],
                                     hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        switch recipe {
        case .standard:
            return SleepStagerV2.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
        case .restless:
            return SleepStagerV2.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp,
                                              restless: .remOnly)
        case .trained:
            return SleepStagerTrained.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
        }
    }
}
