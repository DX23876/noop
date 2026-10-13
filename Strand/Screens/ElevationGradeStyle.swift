import SwiftUI
import StrandDesign

/// What a grade looks like on screen: the cardio colour on the level and descents, warming to the Effort
/// colour where a climb steepens. One place, so the profile, the live grade and the steepest stat agree.
enum ElevationGradeStyle {
    /// A climb this steep or steeper draws in the full Effort colour.
    static let steepGrade = 0.08
    /// A climb from this grade draws in the Effort colour.
    static let moderateGrade = 0.03

    static func color(forGrade grade: Double) -> Color {
        if grade >= steepGrade {
            StrandPalette.effortBright
        } else if grade >= moderateGrade {
            StrandPalette.effortColor
        } else {
            StrandPalette.cardioColor
        }
    }
}
