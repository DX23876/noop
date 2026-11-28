import Foundation
import StrandAnalytics

/// The words of Training Load phase 2 (docs/fork/TRAINING_LOAD_PLAN.md §8), one place for Today, the Training tab,
/// Training Load and the morning notification, so the same advice always reads the same (Q5). Plain everyday
/// words, no method names (Q2).
enum TrainingGuidanceText {
    static func title(_ stance: AdviceStance) -> String {
        switch stance {
        case .push: return String(localized: "Push today")
        case .steady: return String(localized: "Steady today")
        case .easy: return String(localized: "Easy today")
        case .rest: return String(localized: "Rest today")
        }
    }

    static func symbol(_ stance: AdviceStance) -> String {
        switch stance {
        case .push: return "flame.fill"
        case .steady: return "figure.walk"
        case .easy: return "leaf.fill"
        case .rest: return "bed.double.fill"
        }
    }

    static func reason(_ advice: MorningAdviceReading) -> String {
        switch advice.state {
        case .waitingForNight: return String(localized: "Waiting for last night. The advice follows once your Charge is in.")
        case .done, .ready: break
        }
        switch advice.reason {
        case .illness: return String(localized: "You're unwell or a health signal is up. Rest and recover today.")
        case .strainedRecovery:
            return String(localized: "Your recovery is strained and your training is well above usual. Rest today.")
        case .lowCharge: return String(localized: "Your Charge is low. Keep today easy.")
        case .strengthWellAbove:
            return String(localized: "Strength is well above your usual. Keep it easy there, cardio is free.")
        case .cardioWellAbove:
            return String(localized: "Cardio is well above your usual. Keep it easy there, strength is free.")
        case .bothWellAbove: return String(localized: "Your training is well above your usual. Keep today easy.")
        case .planned: return String(localized: "Your planned session fits today.")
        case .plannedShorter: return String(localized: "Your planned session fits, a little shorter or lighter today.")
        case .behindGoal:
            return String(localized: "Your week is behind your goal and you're well recovered. A longer session fits today.")
        case .steady: return String(localized: "A normal day. Train as usual.")
        case .noNight: return String(localized: "No night was measured, so this reads your week only.")
        }
    }

    static func easierFits(_ title: String) -> String {
        String(localized: "An easier session fits today better than \(title).")
    }
    static let moveToTomorrow = String(localized: "Move to tomorrow")
    static let doneLine = String(localized: "Done for today. The advice holds for the rest of the day.")
    static let ateTooLittle = String(localized: "You ate well under your plan this week. Eat enough before you train hard.")
    static let overline = String(localized: "Today's advice")

    static func offer(_ offer: TrainingOffer) -> String {
        switch offer {
        case .planned(let title): return title
        case .cardio(let sport, let minutes): return String(localized: "\(minutes) min \(sport)")
        case .strength(let group, let sets): return String(localized: "\(sets) hard sets \(muscleGroup(group))")
        case .easyMovement: return String(localized: "Easy walk or stretching")
        case .startWalk(let minutes): return String(localized: "\(minutes) min brisk walk")
        }
    }

    static func offerSymbol(_ offer: TrainingOffer) -> String {
        switch offer {
        case .planned: return "calendar"
        case .cardio: return "heart.fill"
        case .strength: return "dumbbell.fill"
        case .easyMovement: return "figure.cooldown"
        case .startWalk: return "figure.walk"
        }
    }

    static func muscleGroup(_ raw: String) -> String {
        switch raw {
        case "abdominals": return String(localized: "Abs")
        case "shoulders": return String(localized: "Shoulders")
        case "biceps": return String(localized: "Biceps")
        case "triceps": return String(localized: "Triceps")
        case "forearms": return String(localized: "Forearms")
        case "quadriceps": return String(localized: "Quads")
        case "hamstrings": return String(localized: "Hamstrings")
        case "calves": return String(localized: "Calves")
        case "glutes": return String(localized: "Glutes")
        case "abductors": return String(localized: "Abductors")
        case "adductors": return String(localized: "Adductors")
        case "lats": return String(localized: "Lats")
        case "upper_back": return String(localized: "Upper back")
        case "traps": return String(localized: "Traps")
        case "lower_back": return String(localized: "Lower back")
        case "chest": return String(localized: "Chest")
        case "neck": return String(localized: "Neck")
        case "full_body": return String(localized: "Full body")
        default: return raw
        }
    }

    // MARK: Enough

    static let enoughTitle = String(localized: "Enough this week")

    static func minutesLine(_ week: EnoughWeek) -> String {
        String(localized: "\(week.equivalentMinutes) of \(week.target.minutesLow) active minutes")
    }

    static func strengthLine(_ week: EnoughWeek) -> String {
        String(localized: "\(week.strengthDays) of \(week.target.strengthDaysLow) strength days")
    }

    static func everydayLine(_ week: EnoughWeek) -> String? {
        week.everydayMinutes > 0 ? String(localized: "\(week.everydayMinutes) of them from everyday movement") : nil
    }

    static func ratedLine(_ week: EnoughWeek) -> String? {
        week.ratedMinutes > 0 ? String(localized: "\(week.ratedMinutes) of them counted by your rating") : nil
    }

    static let enoughCaption = String(localized: "Minutes count from 40 % of your heart-rate range, measured against your own heart, so the same rule holds for every body. Vigorous minutes count double. The targets are for adults and are not adjusted for pregnancy.")
    static let balanceHint = String(localized: "From 65, the WHO also recommends balance and strength work on three days a week.")
    static let carried = String(localized: "You reached your minutes in three of the last four weeks.")

    // MARK: The verdict against the goal

    static func note(_ note: LaneGoalNote) -> String {
        switch note {
        case .carriesWeightLoss: return String(localized: "Carries your weight loss")
        case .strengthHeld: return String(localized: "Strength held")
        case .meetsGuideline: return String(localized: "Meets the guideline")
        case .goalTooNew: return String(localized: "Your goal is new: this is only described for two weeks.")
        case .paused: return String(localized: "Your goal is paused, so the verdict rests.")
        case .checkLoadOrDeficit:
            return String(localized: "Strength is falling fast while your weight drops fast. Look at your training load or your deficit.")
        }
    }

    static let ateOverPlan = String(localized: "Your weight has stalled while your complete food days were over plan. That is the food, not the cardio.")
    static let proteinLow = String(localized: "Protein was under 80 % of your goal on your complete food days, a possible reason for the strength.")

    // MARK: Settings

    static func focus(_ focus: TrainingFocus?) -> String {
        switch focus {
        case nil: return String(localized: "Automatic")
        case .loseWeight: return String(localized: "Lose weight")
        case .fitness: return String(localized: "Fitness")
        case .strength: return String(localized: "Strength")
        case .health: return String(localized: "Health")
        }
    }

    static let focusTitle = String(localized: "Focus")
    static let focusCaption = String(localized: "Training Load judges your training against this. Automatic reads your diet plan and your goals.")
    static let pulseTitle = String(localized: "My pulse doesn't show my effort")
    static let pulseCaption = String(localized: "For example with medication that slows the heart, or a pacemaker. Minutes then count by duration and your rating.")
    static let morningTitle = String(localized: "Morning advice")
    static let morningCaption = String(localized: "One notification in the morning with today's advice. None while the coach's morning brief is on.")
    static let labTitle = String(localized: "New fitness markers")
    static let labCaption = String(localized: "Three markers from your walks and runs. They only inform you until they have passed their check.")

    // MARK: Lab

    static func instrumentTitle(_ kind: String) -> String {
        switch kind {
        case "cadence": return String(localized: "Pulse at your usual walking pace")
        case "recovery": return String(localized: "Pulse drop after hard sessions")
        default: return String(localized: "Pulse at your usual pace on flat ground")
        }
    }

    static func direction(_ d: InstrumentDirection) -> String {
        switch d {
        case .improving: return String(localized: "Getting better")
        case .worsening: return String(localized: "Getting worse")
        case .unclear: return String(localized: "No clear direction")
        case .unknown: return String(localized: "Not enough sessions yet")
        }
    }

    static func check(passes: Bool, pairs: Int?) -> String {
        if passes { return String(localized: "Check passed") }
        return String(localized: "Check: \(pairs ?? 0) of 8 weekly comparisons so far")
    }

    static let everydayFitness = String(localized: "Losing weight lowers this pulse too. That is real everyday fitness, not VO₂max.")
}
