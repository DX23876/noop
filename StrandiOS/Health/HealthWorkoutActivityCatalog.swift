import Foundation
import HealthKit
import StrandAnalytics

/// The single HealthKit-to-NOOP activity map. Every current SDK case is named here; future raw values
/// remain importable through the `@unknown default` instead of collapsing silently into cardio.
enum HealthWorkoutActivityCatalog {
    static func descriptor(for type: HKWorkoutActivityType) -> TrainingActivityDescriptor {
        func d(_ id: String, _ name: String, _ kind: TrainingActivityKind,
               distance: Bool = false, route: Bool = false) -> TrainingActivityDescriptor {
            .init(id: "healthkit.\(id)", storedName: name, displayKey: name, kind: kind,
                  supportsDistance: distance, supportsRoute: route)
        }
        switch type {
        case .functionalStrengthTraining: return d("functional-strength", "Functional strength training", .strength)
        case .traditionalStrengthTraining: return d("traditional-strength", "Strength Training", .strength)
        case .coreTraining: return d("core", "Core training", .strength)

        case .running: return d("running", "Running", .endurance, distance: true, route: true)
        case .walking: return d("walking", "Walking", .endurance, distance: true, route: true)
        case .hiking: return d("hiking", "Hiking", .endurance, distance: true, route: true)
        case .cycling: return d("cycling", "Cycling", .endurance, distance: true, route: true)
        case .rowing: return d("rowing", "Rowing", .endurance, distance: true)
        case .elliptical: return d("elliptical", "Elliptical", .endurance, distance: true)
        case .swimming: return d("swimming", "Swimming", .endurance, distance: true)
        case .waterFitness: return d("water-fitness", "Water fitness", .endurance)
        case .stairClimbing: return d("stair-climbing", "Stair climbing", .endurance, distance: true)
        case .stairs: return d("stairs", "Stairs", .endurance, distance: true)
        case .stepTraining: return d("step-training", "Step training", .endurance)
        case .paddleSports: return d("paddle-sports", "Paddling", .endurance, distance: true, route: true)
        case .handCycling: return d("hand-cycling", "Hand cycling", .endurance, distance: true, route: true)
        case .wheelchairWalkPace: return d("wheelchair-walk", "Wheelchair walk", .endurance, distance: true, route: true)
        case .wheelchairRunPace: return d("wheelchair-run", "Wheelchair run", .endurance, distance: true, route: true)
        case .crossCountrySkiing: return d("cross-country-skiing", "Cross-country skiing", .endurance, distance: true, route: true)
        case .downhillSkiing: return d("downhill-skiing", "Downhill skiing", .endurance, distance: true, route: true)
        case .snowboarding: return d("snowboarding", "Snowboarding", .endurance, distance: true, route: true)
        case .skatingSports: return d("skating", "Skating", .endurance, distance: true, route: true)

        case .americanFootball: return d("american-football", "American football", .conditioning)
        case .australianFootball: return d("australian-football", "Australian football", .conditioning)
        case .badminton: return d("badminton", "Badminton", .conditioning)
        case .baseball: return d("baseball", "Baseball", .conditioning)
        case .basketball: return d("basketball", "Basketball", .conditioning)
        case .boxing: return d("boxing", "Boxing", .conditioning)
        case .climbing: return d("climbing", "Climbing", .conditioning)
        case .cricket: return d("cricket", "Cricket", .conditioning)
        case .crossTraining: return d("cross-training", "Cross training", .conditioning)
        case .dance: return d("dance", "Dance", .conditioning)
        case .danceInspiredTraining: return d("dance-inspired", "Dance-inspired training", .conditioning)
        case .cardioDance: return d("cardio-dance", "Cardio dance", .conditioning)
        case .socialDance: return d("social-dance", "Social dance", .conditioning)
        case .fencing: return d("fencing", "Fencing", .conditioning)
        case .gymnastics: return d("gymnastics", "Gymnastics", .conditioning)
        case .handball: return d("handball", "Handball", .conditioning)
        case .hockey: return d("hockey", "Hockey", .conditioning)
        case .lacrosse: return d("lacrosse", "Lacrosse", .conditioning)
        case .martialArts: return d("martial-arts", "Martial arts", .conditioning)
        case .mixedMetabolicCardioTraining:
            return d("mixed-metabolic-cardio", "Mixed metabolic cardio training", .conditioning)
        case .mixedCardio: return d("mixed-cardio", "Mixed cardio", .conditioning)
        case .play: return d("play", "Play", .conditioning)
        case .racquetball: return d("racquetball", "Racquetball", .conditioning)
        case .rugby: return d("rugby", "Rugby", .conditioning)
        case .soccer: return d("soccer", "Soccer", .conditioning)
        case .softball: return d("softball", "Softball", .conditioning)
        case .squash: return d("squash", "Squash", .conditioning)
        case .surfingSports: return d("surfing", "Surfing", .conditioning, distance: true, route: true)
        case .tableTennis: return d("table-tennis", "Table tennis", .conditioning)
        case .tennis: return d("tennis", "Tennis", .conditioning)
        case .trackAndField: return d("track-field", "Track and field", .conditioning, distance: true, route: true)
        case .volleyball: return d("volleyball", "Volleyball", .conditioning)
        case .waterPolo: return d("water-polo", "Water polo", .conditioning)
        case .wrestling: return d("wrestling", "Wrestling", .conditioning)
        case .highIntensityIntervalTraining: return d("hiit", "HIIT", .conditioning)
        case .jumpRope: return d("jump-rope", "Jump rope", .conditioning)
        case .kickboxing: return d("kickboxing", "Kickboxing", .conditioning)
        case .discSports: return d("disc-sports", "Disc sports", .conditioning)
        case .fitnessGaming: return d("fitness-gaming", "Fitness gaming", .conditioning)
        case .pickleball: return d("pickleball", "Pickleball", .conditioning)

        case .yoga: return d("yoga", "Yoga", .mobilityRecovery)
        case .pilates: return d("pilates", "Pilates", .mobilityRecovery)
        case .barre: return d("barre", "Barre", .mobilityRecovery)
        case .flexibility: return d("flexibility", "Flexibility", .mobilityRecovery)
        case .mindAndBody: return d("mind-body", "Mind and body", .mobilityRecovery)
        case .preparationAndRecovery: return d("preparation-recovery", "Preparation and recovery", .mobilityRecovery)
        case .taiChi: return d("tai-chi", "Tai Chi", .mobilityRecovery)
        case .cooldown: return d("cooldown", "Cooldown", .mobilityRecovery)

        case .archery: return d("archery", "Archery", .outdoorRecreation)
        case .bowling: return d("bowling", "Bowling", .outdoorRecreation)
        case .curling: return d("curling", "Curling", .outdoorRecreation)
        case .equestrianSports: return d("equestrian", "Equestrian sports", .outdoorRecreation, distance: true, route: true)
        case .fishing: return d("fishing", "Fishing", .outdoorRecreation)
        case .golf: return d("golf", "Golf", .outdoorRecreation, distance: true, route: true)
        case .hunting: return d("hunting", "Hunting", .outdoorRecreation, distance: true, route: true)
        case .sailing: return d("sailing", "Sailing", .outdoorRecreation, distance: true, route: true)
        case .snowSports: return d("snow-sports", "Snow sports", .outdoorRecreation, distance: true, route: true)
        case .waterSports: return d("water-sports", "Water sports", .outdoorRecreation, distance: true, route: true)
        case .underwaterDiving: return d("underwater-diving", "Underwater diving", .outdoorRecreation)

        case .swimBikeRun: return d("swim-bike-run", "Swim Bike Run", .multisport, distance: true, route: true)
        case .transition: return d("transition", "Transition", .multisport)
        case .other: return d("other", "Other activity", .other)
        @unknown default:
            return d("unknown-\(type.rawValue)", "Other activity", .other)
        }
    }
}
