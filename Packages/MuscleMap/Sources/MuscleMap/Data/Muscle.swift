//
//  Muscle.swift
//  MuscleMap
//
//  Created by Melih Colpan on 2026-02-09.
//  Copyright © 2026 Melih Colpan. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation

/// Represents all available muscle groups that can be highlighted on the body.
public enum Muscle: String, CaseIterable, Codable, Identifiable, Sendable {
    case abs
    case biceps
    case calves
    case chest
    case deltoids
    case feet
    case forearm
    case gluteal
    case hamstring
    case hands
    case head
    case knees
    case lowerBack = "lower-back"
    case obliques
    case quadriceps
    case tibialis
    case trapezius
    case triceps
    case upperBack = "upper-back"

    // New muscle groups
    case rotatorCuff = "rotator-cuff"
    case serratus
    case rhomboids

    // Sub-groups
    case ankles
    case adductors
    case neck
    case hipFlexors = "hip-flexors"
    case upperChest = "upper-chest"
    case lowerChest = "lower-chest"
    case innerQuad = "inner-quad"
    case outerQuad = "outer-quad"
    case upperAbs = "upper-abs"
    case lowerAbs = "lower-abs"
    case frontDeltoid = "front-deltoid"
    case rearDeltoid = "rear-deltoid"
    case upperTrapezius = "upper-trapezius"
    case lowerTrapezius = "lower-trapezius"

    public var id: String { rawValue }

    /// Localized display name for the muscle.
    public var displayName: String {
        displayName(locale: nil)
    }

    /// Localized display name in a specific locale. This is useful for exports and deterministic
    /// tests; normal UI should use `displayName` so it follows the app language.
    public func displayName(locale: Locale?) -> String {
        Bundle.module.muscleMapLocalizedString("muscle.\(localizationKey)", locale: locale)
    }

    /// Key used for localization lookup. Maps Swift case names to xcstrings keys.
    private var localizationKey: String {
        switch self {
        case .abs: return "abs"
        case .adductors: return "adductors"
        case .ankles: return "ankles"
        case .biceps: return "biceps"
        case .calves: return "calves"
        case .chest: return "chest"
        case .deltoids: return "deltoids"
        case .feet: return "feet"
        case .forearm: return "forearm"
        case .gluteal: return "gluteal"
        case .hamstring: return "hamstring"
        case .hands: return "hands"
        case .head: return "head"
        case .knees: return "knees"
        case .lowerBack: return "lowerBack"
        case .neck: return "neck"
        case .obliques: return "obliques"
        case .quadriceps: return "quadriceps"
        case .tibialis: return "tibialis"
        case .trapezius: return "trapezius"
        case .triceps: return "triceps"
        case .upperBack: return "upperBack"
        case .rotatorCuff: return "rotatorCuff"
        case .hipFlexors: return "hipFlexors"
        case .serratus: return "serratus"
        case .rhomboids: return "rhomboids"
        case .upperChest: return "upperChest"
        case .lowerChest: return "lowerChest"
        case .innerQuad: return "innerQuad"
        case .outerQuad: return "outerQuad"
        case .upperAbs: return "upperAbs"
        case .lowerAbs: return "lowerAbs"
        case .frontDeltoid: return "frontDeltoid"
        case .rearDeltoid: return "rearDeltoid"
        case .upperTrapezius: return "upperTrapezius"
        case .lowerTrapezius: return "lowerTrapezius"
        }
    }

    /// Whether this is a cosmetic part (head/hair) rather than a muscle.
    public var isCosmeticPart: Bool {
        self == .head
    }

    /// Sub-groups belonging to this muscle group. Empty if this muscle has no sub-groups.
    public var subGroups: [Muscle] {
        switch self {
        case .chest: return [.upperChest, .lowerChest]
        case .quadriceps: return [.innerQuad, .outerQuad, .hipFlexors]
        case .abs: return [.upperAbs, .lowerAbs]
        case .deltoids: return [.frontDeltoid, .rearDeltoid]
        case .trapezius: return [.upperTrapezius, .lowerTrapezius]
        case .obliques: return [.serratus]
        case .feet: return [.ankles]
        case .hamstring: return [.adductors]
        case .head: return [.neck]
        default: return []
        }
    }

    /// The parent muscle group, if this muscle is a sub-group.
    public var parentGroup: Muscle? {
        switch self {
        case .upperChest, .lowerChest: return .chest
        case .innerQuad, .outerQuad, .hipFlexors: return .quadriceps
        case .upperAbs, .lowerAbs: return .abs
        case .frontDeltoid, .rearDeltoid: return .deltoids
        case .upperTrapezius, .lowerTrapezius: return .trapezius
        case .serratus: return .obliques
        case .ankles: return .feet
        case .adductors: return .hamstring
        case .neck: return .head
        default: return nil
        }
    }

    /// Whether this muscle is a sub-group of another muscle.
    public var isSubGroup: Bool {
        parentGroup != nil
    }

    /// Whether this sub-group is always rendered even when sub-groups are hidden.
    /// When tapped in default mode, the parent muscle is returned instead.
    public var isAlwaysVisibleSubGroup: Bool {
        switch self {
        case .ankles, .adductors, .neck: return true
        default: return false
        }
    }
}

/// Internal-only slug that includes hair for rendering purposes.
enum BodySlug: String, CaseIterable {
    case abs
    case biceps
    case calves
    case chest
    case deltoids
    case feet
    case forearm
    case gluteal
    case hamstring
    case hands
    case hair
    case head
    case knees
    case lowerBack = "lower-back"
    case obliques
    case quadriceps
    case tibialis
    case trapezius
    case triceps
    case upperBack = "upper-back"

    // New muscle groups
    case rotatorCuff = "rotator-cuff"
    case serratus
    case rhomboids

    // Sub-groups
    case ankles
    case adductors
    case neck
    case hipFlexors = "hip-flexors"
    case upperChest = "upper-chest"
    case lowerChest = "lower-chest"
    case innerQuad = "inner-quad"
    case outerQuad = "outer-quad"
    case upperAbs = "upper-abs"
    case lowerAbs = "lower-abs"
    case frontDeltoid = "front-deltoid"
    case rearDeltoid = "rear-deltoid"
    case upperTrapezius = "upper-trapezius"
    case lowerTrapezius = "lower-trapezius"

    var muscle: Muscle? {
        switch self {
        case .hair: return nil
        default: return Muscle(rawValue: rawValue)
        }
    }
}
