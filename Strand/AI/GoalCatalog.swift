import Foundation
import WhoopStore

/// The areas the catalog groups its templates under when a goal is set (plan §9 step 1).
enum GoalCatalogArea: String, CaseIterable, Identifiable {
    case endurance, training, fitness, daily, body, sleep, habits

    var id: String { rawValue }

    /// Catalog key.
    var title: String {
        switch self {
        case .endurance: return "Endurance"
        case .training:  return "Strength and training"
        case .fitness:   return "Heart and fitness"
        case .daily:     return "Everyday activity"
        case .body:      return "Body"
        case .sleep:     return "Sleep and recovery"
        case .habits:    return "Habits"
        }
    }

    var icon: String {
        switch self {
        case .endurance: return "figure.run"
        case .training:  return "dumbbell.fill"
        case .fitness:   return "heart.fill"
        case .daily:     return "figure.walk"
        case .body:      return "scalemass.fill"
        case .sleep:     return "moon.stars.fill"
        case .habits:    return "checklist"
        }
    }
}

/// One template as the catalog shows it: what it is called, which area it sits in, which sports it
/// offers and whether the walkthrough already carries it. What it measures is `GoalTemplateID`'s.
struct GoalTemplate: Identifiable, Equatable {
    let id: GoalTemplateID
    let area: GoalCatalogArea
    /// Catalog keys.
    let title: String
    let blurb: String
    let icon: String
    /// The sports a wearer can pick from, first one preselected; empty when the template takes none.
    /// An empty filter in the pick means every sport.
    let sportChoices: [SportChoice]
    /// Part of the first walkthrough of the catalog (plan Q1). The rest follows once that is reviewed.
    let inWalkthrough: Bool

    struct SportChoice: Equatable, Identifiable {
        /// Catalog key.
        let label: String
        let filter: [String]
        var id: String { label }
    }

    var shape: GoalShape { id.metric.baseShape }
}

enum GoalCatalog {

    static let endurance: [GoalTemplate.SportChoice] = [
        .init(label: "Running", filter: ["Running"]),
        .init(label: "Cycling", filter: ["Cycling"]),
        .init(label: "Walking", filter: ["Walking"]),
        .init(label: "Swimming", filter: ["Swimming"]),
        .init(label: "All sports", filter: []),
    ]

    static let training: [GoalTemplate.SportChoice] = [
        .init(label: "Strength", filter: ["Strength"]),
        .init(label: "Running", filter: ["Running"]),
        .init(label: "Cycling", filter: ["Cycling"]),
        .init(label: "All sports", filter: []),
    ]

    static let all: [GoalTemplate] = [
        .init(id: .distanceTotal, area: .endurance, title: "Collect kilometres",
              blurb: "A distance to gather by a date, like 1,000 km this year.",
              icon: "point.topleft.down.to.point.bottomright.curvepath", sportChoices: endurance, inWalkthrough: true),
        .init(id: .longest, area: .endurance, title: "Reach a distance",
              blurb: "Go further than before, like your first 10 km.",
              icon: "flag.checkered", sportChoices: endurance, inWalkthrough: true),
        .init(id: .timeTotal, area: .endurance, title: "Collect training hours",
              blurb: "Hours of training to gather by a date.",
              icon: "timer", sportChoices: training, inWalkthrough: false),
        .init(id: .workoutsTotal, area: .endurance, title: "Collect workouts",
              blurb: "A number of workouts by a date, like 100 this year.",
              icon: "number", sportChoices: training, inWalkthrough: false),
        .init(id: .event, area: .endurance, title: "Race on a date",
              blurb: "Be ready for a race, like a half marathon in March.",
              icon: "calendar", sportChoices: [], inWalkthrough: false),
        .init(id: .paceAverage, area: .endurance, title: "Run faster",
              blurb: "A quicker average pace on runs from 3 km.",
              icon: "speedometer", sportChoices: [], inWalkthrough: false),
        .init(id: .trainingWeekly, area: .training, title: "Train regularly",
              blurb: "A number of sessions every week, kept up over months.",
              icon: "calendar.badge.checkmark", sportChoices: training, inWalkthrough: true),
        .init(id: .setsWeekly, area: .training, title: "Working sets per week",
              blurb: "Training volume from your lifting log.",
              icon: "square.3.layers.3d", sportChoices: [], inWalkthrough: false),
        .init(id: .vo2max, area: .fitness, title: "Raise VO2max",
              blurb: "Your aerobic fitness, read from your strap.",
              icon: "lungs.fill", sportChoices: [], inWalkthrough: false),
        .init(id: .restingHr, area: .fitness, title: "Lower resting heart rate",
              blurb: "A calmer heart at rest, read every night.",
              icon: "heart.fill", sportChoices: [], inWalkthrough: false),
        .init(id: .hrvAverage, area: .fitness, title: "Raise HRV",
              blurb: "Your average heart-rate variability over four weeks.",
              icon: "waveform.path.ecg", sportChoices: [], inWalkthrough: false),
        .init(id: .zoneWeekly, area: .fitness, title: "Zone minutes every week",
              blurb: "Minutes in zone 2 and above, like the WHO's 150.",
              icon: "heart.circle", sportChoices: [], inWalkthrough: false),
        .init(id: .stepDays, area: .daily, title: "Step days",
              blurb: "A step count on a number of days each week.",
              icon: "figure.walk", sportChoices: [], inWalkthrough: false),
        .init(id: .stepsTotal, area: .daily, title: "Collect steps",
              blurb: "Steps to gather by a date.",
              icon: "shoeprints.fill", sportChoices: [], inWalkthrough: false),
        .init(id: .activeEnergyWeekly, area: .daily, title: "Active energy every week",
              blurb: "Active calories each week, as NOOP estimates them.",
              icon: "flame.fill", sportChoices: [], inWalkthrough: false),
        .init(id: .trainingDays, area: .daily, title: "Active days",
              blurb: "Days with at least one workout each week.",
              icon: "calendar", sportChoices: [], inWalkthrough: false),
        .init(id: .weightLose, area: .body, title: "Lose weight",
              blurb: "A lower body weight, with or without a date.",
              icon: "arrow.down.circle", sportChoices: [], inWalkthrough: true),
        .init(id: .weightGain, area: .body, title: "Gain weight",
              blurb: "A higher body weight, with or without a date.",
              icon: "arrow.up.circle", sportChoices: [], inWalkthrough: false),
        .init(id: .weightMaintain, area: .body, title: "Keep your weight",
              blurb: "Stay within a band around a weight.",
              icon: "equal.circle", sportChoices: [], inWalkthrough: false),
        .init(id: .bodyFat, area: .body, title: "Lower body fat",
              blurb: "Body fat from a smart scale.",
              icon: "percent", sportChoices: [], inWalkthrough: false),
        .init(id: .leanMass, area: .body, title: "Build lean mass",
              blurb: "Lean mass from a smart scale.",
              icon: "figure.strengthtraining.traditional", sportChoices: [], inWalkthrough: false),
        .init(id: .waist, area: .body, title: "Smaller waist",
              blurb: "Waist circumference, measured by you.",
              icon: "ruler", sportChoices: [], inWalkthrough: false),
        .init(id: .sleepAverage, area: .sleep, title: "Sleep longer",
              blurb: "Your average sleep over four weeks.",
              icon: "bed.double.fill", sportChoices: [], inWalkthrough: true),
        .init(id: .sleepNightsWeekly, area: .sleep, title: "Nights of enough sleep",
              blurb: "A number of long enough nights each week.",
              icon: "moon.stars.fill", sportChoices: [], inWalkthrough: false),
        .init(id: .recoveryAverage, area: .sleep, title: "Recover better",
              blurb: "Your average recovery over four weeks.",
              icon: "battery.75", sportChoices: [], inWalkthrough: false),
        .init(id: .restDays, area: .sleep, title: "Keep rest days",
              blurb: "Days without a workout each week.",
              icon: "leaf.fill", sportChoices: [], inWalkthrough: false),
        .init(id: .hydration, area: .habits, title: "Drink enough",
              blurb: "Reach your drinking goal on a number of days.",
              icon: "drop.fill", sportChoices: [], inWalkthrough: false),
        .init(id: .journalHabit, area: .habits, title: "Keep a journal habit",
              blurb: "A habit from your journal, like no alcohol.",
              icon: "book.closed", sportChoices: [], inWalkthrough: false),
    ]

    static func template(_ id: GoalTemplateID) -> GoalTemplate? { all.first { $0.id == id } }

    static func template(for goal: CoachGoal) -> GoalTemplate? {
        goal.templateId.flatMap(GoalTemplateID.init(rawValue:)).flatMap(template)
    }

    /// The templates the setup offers now: the walkthrough's five until the rest is switched on.
    static var offered: [GoalTemplate] { all.filter(\.inWalkthrough) }

    enum Availability: Equatable {
        case available
        /// Shown greyed with the reason (catalog key).
        case unavailable(String)
    }

    /// Whether the data a template reads has arrived. A template is never hidden for lack of data, only
    /// greyed with the reason, so the wearer knows what would switch it on.
    static func availability(_ id: GoalTemplateID, workouts: [WorkoutRow], days: [DailyMetric]) -> Availability {
        switch id {
        case .distanceTotal, .longest:
            return workouts.contains { ($0.distanceM ?? 0) > 0 }
                ? .available : .unavailable("Needs a workout with a distance, from your phone, a watch or a file")
        case .sleepAverage:
            return days.contains { $0.totalSleepMin != nil }
                ? .available : .unavailable("Needs nights recorded by your strap")
        case .trainingWeekly, .weightLose:
            return .available
        default:
            return .unavailable("Comes after the first walkthrough")
        }
    }
}
