import SwiftUI
import StrandDesign
import StrandTraining
import MuscleMap

/// A small picture of what an exercise, a session or a plan trains: the body with the muscles it works
/// lit in the strength colour.
///
/// Every list of exercises used to carry one of three glyphs, a dumbbell, a stopwatch or a runner, which
/// said nothing about the exercise: a bench press and a curl looked the same. This says what the thing
/// in the row actually does, from the muscle mapping the analytics already use, so it is information
/// rather than ornament and it needs no downloaded media to appear.
///
/// Where the media pack IS downloaded, the photograph of the movement is the better picture and the
/// callers prefer it; this is what stands in its place, not a fallback glyph.
struct TrainingMusclePicture: View {
    /// Muscle id to involvement, as `TrainingMuscleProjection` counts it.
    let values: [String: Double]
    /// Both halves of the body, or just the side that carries the work.
    var showsBack = false
    /// Which face to draw when only one is shown; by default the one the work is on.
    var side: BodySide?
    var height: CGFloat = CoachPictureSize.small

    /// One gap, and the figure's own shape, so the body fills the height it is given instead of
    /// sitting small in the middle of a frame that is wider than it is.
    private static let gap = NoopMetrics.space1
    private var figureWidth: CGFloat { height * BodyAnatomy.aspectRatio() }

    var body: some View {
        HStack(spacing: Self.gap) {
            figure(showsBack ? .front : (side ?? Self.preferredSide(values)))
            if showsBack { figure(.back) }
        }
        .frame(width: showsBack ? figureWidth * 2 + Self.gap : figureWidth, height: height)
        .accessibilityHidden(true)
    }

    private func figure(_ side: BodySide) -> some View {
        MuscleMap.BodyView(gender: .male, side: side, style: TrainingMuscleMapAppearance.style)
            .heatmap(TrainingMuscleMapAppearance.intensities(values),
                     colorScale: TrainingMuscleMapAppearance.scale)
            .showSubGroups()
    }

    /// Muscles only one face of the body draws, from the map's own shapes rather than a list kept by
    /// hand. A chin-up drawn from the front is a grey man: the work is all behind him.
    private static let frontOnly = BodyAnatomy.muscles(side: .front)
        .subtracting(BodyAnatomy.muscles(side: .back))
    private static let backOnly = BodyAnatomy.muscles(side: .back)
        .subtracting(BodyAnatomy.muscles(side: .front))

    /// The face of the body that carries this exercise's work, so a row showing one figure shows the
    /// one with something on it. A muscle both faces draw settles nothing and counts for neither.
    static func preferredSide(_ values: [String: Double]) -> BodySide {
        var front = 0.0
        var back = 0.0
        for (id, value) in values {
            guard let muscle = TrainingMuscleMapAppearance.muscle(id) else { continue }
            if frontOnly.contains(muscle) { front += value }
            if backOnly.contains(muscle) { back += value }
        }
        return back > front ? .back : .front
    }

    /// The muscles one exercise works, at full weight for its primary and half for the rest, which is the
    /// same credit the muscle map and the plan review give.
    ///
    /// Work credited to a muscle the figure has no shape for is moved up to the group it belongs to.
    /// The map has no upper trapezius, so a barbell shrug lit nothing at all and its row showed a grey
    /// body; it now lights the trapezius. The involvement figures themselves are untouched, this is
    /// only what the picture can show.
    static func values(for exercise: TrainingExercise) -> [String: Double] {
        guard let anatomy = TrainingMuscleProjection.anatomy(for: exercise) else { return [:] }
        var out: [String: Double] = [:]
        for id in anatomy.primaryMuscleIds { add(id, 1, to: &out) }
        for id in anatomy.secondaryMuscleIds { add(id, 0.5, to: &out) }
        return out
    }

    private static func add(_ id: String, _ value: Double, to out: inout [String: Double]) {
        var key = id
        if let muscle = TrainingMuscleMapAppearance.muscle(id), !BodyAnatomy.isDrawn(muscle),
           let parent = muscle.parentGroup, BodyAnatomy.isDrawn(parent),
           let parentId = TrainingMuscleMapAppearance.ids(for: parent).first {
            key = parentId
        }
        out[key] = max(out[key] ?? 0, value)
    }
}

/// The picture a row shows for one exercise: the demonstration when the media pack is there, otherwise
/// the body with its muscles lit. One decision, made once, so every list that shows exercises shows the
/// same thing.
struct TrainingExercisePicture: View {
    let exercise: TrainingExercise
    var side: CGFloat = CoachPictureSize.small
    @ObservedObject private var media = ExerciseMediaStore.shared

    var body: some View {
        Group {
            if media.isAvailable, let still = media.mediaURL(for: exercise, variant: .still) {
                ExerciseMediaThumbnail(url: still, side: side)
            } else {
                let shape = RoundedRectangle(cornerRadius: ExerciseMediaThumbnail.cornerRadius)
                TrainingMusclePicture(values: TrainingMusclePicture.values(for: exercise),
                                      height: side - NoopMetrics.space2)
                    .frame(width: side, height: side)
                    // A plate a step lighter than the row holds the figure; without it the body floats
                    // on the card and reads as a smudge.
                    .background(StrandPalette.surfaceRaised, in: shape)
                    .overlay(shape.strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The week a plan runs: its training days lit, its rest days left dark.
///
/// A plan is a shape in a week before it is a list of exercises, and the builder's questions had no
/// picture of what they were making: seven controls and a paragraph of text. This is that picture,
/// and it is drawn from the same answer the build itself uses, so it cannot promise a week the plan
/// does not have.
struct TrainingWeekStrip: View {
    let days: Set<TrainingWeekday>
    /// The sessions in the order the week runs them, shown under the strip where there is room.
    var titles: [String] = []
    var height: CGFloat = TrainingWeekStrip.tall
    /// Two heights, not five: a card's own strip, and a compact one inside a list row.
    static let tall: CGFloat = NoopMetrics.space10
    static let compact: CGFloat = NoopMetrics.space8

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                ForEach(TrainingWeekday.allCases, id: \.rawValue) { day in pill(day) }
            }
            if !titles.isEmpty {
                Text(titles.joined(separator: " · "))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(days.count) training days a week"))
    }

    private func pill(_ day: TrainingWeekday) -> some View {
        let trains = days.contains(day)
        let tint = TrainingMuscleMapAppearance.accent
        return Text(Self.letter(day))
            .font(StrandFont.caption.weight(trains ? .bold : .medium))
            .foregroundStyle(trains ? tint : StrandPalette.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(trains ? tint.opacity(0.16) : StrandPalette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: Self.pillRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.pillRadius, style: .continuous)
                .strokeBorder(trains ? tint.opacity(0.55) : .clear, lineWidth: 1))
    }

    private static let pillRadius = NoopMetrics.space3

    /// Monday is 1 here and the calendar's symbols start on Sunday.
    private static func letter(_ day: TrainingWeekday) -> String {
        Calendar.current.veryShortWeekdaySymbols[day.rawValue % 7]
    }
}
