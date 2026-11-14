//
//  BodyAnatomy.swift
//  MuscleMap
//
//  Licensed under the MIT License.
//

import CoreGraphics
import Foundation

/// Which muscles each face of the body actually draws.
///
/// A caller that shows one figure rather than two has to know which face carries a movement's work,
/// and a caller that lights a muscle has to know whether the figure can show it at all: the path data
/// has no shapes for a few sub-groups, so involvement credited to them lights nothing. Both questions
/// are answered here from the path data itself rather than from a hand-kept list, which would go stale
/// the first time a shape is added.
public enum BodyAnatomy {

    /// The muscles this face of the body has shapes for.
    public static func muscles(gender: BodyGender = .male, side: BodySide) -> Set<Muscle> {
        Set(BodyPathProvider.paths(gender: gender, side: side)
            .filter { !$0.allPaths.isEmpty }
            .compactMap { $0.slug.muscle })
    }

    /// The figure's own width-to-height ratio. The renderer fits the body inside whatever frame it is
    /// given and centres it, so a frame of any other shape is dead space around a smaller body.
    public static func aspectRatio(gender: BodyGender = .male, side: BodySide = .front) -> CGFloat {
        let box = BodyPathProvider.viewBox(gender: gender, side: side)
        return box.size.width / box.size.height
    }

    /// Whether either face can draw this muscle.
    public static func isDrawn(_ muscle: Muscle, gender: BodyGender = .male) -> Bool {
        muscles(gender: gender, side: .front).contains(muscle)
            || muscles(gender: gender, side: .back).contains(muscle)
    }
}
