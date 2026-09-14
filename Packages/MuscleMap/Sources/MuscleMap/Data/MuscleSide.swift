//
//  MuscleSide.swift
//  MuscleMap
//
//  Created by Melih Colpan on 2026-02-09.
//  Copyright © 2026 Melih Colpan. All rights reserved.
//  Licensed under the MIT License.
//

import Foundation

/// Represents which side of the body a muscle belongs to.
public enum MuscleSide: String, CaseIterable, Codable, Sendable {
    case left
    case right
    case both

    /// Localized display name.
    public var displayName: String {
        displayName(locale: nil)
    }

    /// Localized display name in a specific locale.
    public func displayName(locale: Locale?) -> String {
        Bundle.module.muscleMapLocalizedString("side.\(rawValue)", locale: locale)
    }
}

/// Represents which face of the body to display.
public enum BodySide: String, CaseIterable, Codable, Sendable {
    case front
    case back

    /// Localized display name.
    public var displayName: String {
        displayName(locale: nil)
    }

    /// Localized display name in a specific locale.
    public func displayName(locale: Locale?) -> String {
        Bundle.module.muscleMapLocalizedString("bodySide.\(rawValue)", locale: locale)
    }
}

/// Represents the body gender model.
public enum BodyGender: String, CaseIterable, Codable, Sendable {
    case male
    case female

    /// Localized display name.
    public var displayName: String {
        displayName(locale: nil)
    }

    /// Localized display name in a specific locale.
    public func displayName(locale: Locale?) -> String {
        Bundle.module.muscleMapLocalizedString("gender.\(rawValue)", locale: locale)
    }
}
