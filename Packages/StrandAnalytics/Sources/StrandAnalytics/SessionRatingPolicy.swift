import Foundation

// SessionRatingPolicy.swift — when is it worth asking "how hard was that session?"
//
// Session RPE × minutes (Foster 1998) is the one load measure that works for every activity, and for
// lifting it is the only internal-load measure NOOP has: heart rate reads a set's pressor response,
// not its cost. It used to be requested after EVERY session, a stroll included, whose answer is
// almost always 1–2 and whose load heart rate already measures. A prompt that fires on every walk
// teaches people to swipe it away, including after the session it was meant for.
//
// So the question is asked where the answer adds something heart rate cannot: where heart rate is a
// poor gauge of the load (lifting, stop-and-go sports, combat, swimming), where NOOP cannot tell what
// the session was, and — for steady endurance and low-load activities — when the session itself
// was substantial. A mountain hike and a walk to the bakery share a sport; they do not share a
// duration or a heart rate, which is why steady sports are judged on the session rather than the name.
public enum SessionRatingPolicy {

    public enum Family: String, CaseIterable, Sendable {
        /// Heart rate understates the load: lifting, bodyweight, circuits, climbing.
        case resistance
        /// Stop-and-go ball, racket and team sports: an average heart rate hides the sprints.
        case intermittent
        /// Combat sports: bursts plus isometric holds.
        case combat
        /// A wrist optical sensor under water is unreliable.
        case swimming
        /// Continuous endurance, where heart rate describes the load well.
        case steadyEndurance
        /// Skill, leisure and recovery activities with little physical load.
        case lowLoad
        /// "Other", "Workout", a detected bout, free text NOOP cannot place.
        case unknown

        /// Families whose load heart rate cannot speak for, so a session is always worth rating.
        public var alwaysWorthRating: Bool {
            switch self {
            case .resistance, .intermittent, .combat, .swimming, .unknown: return true
            case .steadyEndurance, .lowLoad: return false
            }
        }
    }

    /// A steady or low-load session this long is worth rating whatever its heart rate: duration is
    /// where a hike, a long ride or an afternoon of skiing gets hard.
    public static let substantialMinutes = 45.0
    /// Or this share of the heart-rate reserve on average: the lower edge of moderate intensity
    /// (ACSM, 40–59 % HRR), so a hard 30-minute run is asked about and an easy stroll is not.
    public static let substantialReserve = 0.5

    /// Ordered, most specific first: a key is tested only if every family above it missed, so
    /// "Water polo" is a team sport rather than a swim, "Stair climber" is endurance rather than
    /// climbing, and "Kickboxing" is combat whichever of its halves matched. Keys are letters only,
    /// lower-cased, and matched as substrings, so Apple's "HKWorkoutActivityType…" names, WHOOP's
    /// camel case, Oura's snake case and German "Krafttraining" all resolve.
    private static let table: [(Family, [String])] = [
        (.intermittent, ["waterpolo"]),
        (.steadyEndurance, ["stair", "paddleboard", "fitnessgaming", "handcycling", "cyclingwheelchair"]),
        (.lowLoad, ["discgolf", "skydiving", "scuba", "flexibility", "cooldown", "mindandbody",
                    "taichi", "stretch", "meditat", "breath", "yoga", "golf", "bowling", "billiard",
                    "darts", "archery", "curling", "fishing", "hunting", "sailing", "gaming",
                    "motorracing", "motocross", "horseback", "equestrian", "recovery"]),
        (.combat, ["boxing", "martialart", "jiujitsu", "judo", "karate", "taekwondo", "muaythai",
                   "wrestling", "fencing", "mma"]),
        (.resistance, ["strength", "kraft", "weight", "lifting", "bodybuilding", "calisthenic",
                       "crossfit", "bootcamp", "hiit", "highintensity", "functional", "coretraining",
                       "gymnastic", "climbing", "bouldering", "pilates", "barre", "crosstraining"]),
        (.intermittent, ["soccer", "football", "basketball", "handball", "rugby", "hockey", "lacrosse",
                         "netball", "volleyball", "tennis", "squash", "badminton", "racquet", "padel",
                         "pickleball", "baseball", "softball", "cricket", "frisbee", "spikeball",
                         "hurling", "camogie", "paintball", "polo", "trackandfield", "sport"]),
        (.swimming, ["swim", "schwimm"]),
        (.steadyEndurance, ["run", "jog", "lauf", "walk", "hik", "wander", "ruck", "cycl", "bike",
                            "biking", "radfahr",
                            "spin", "row", "elliptical", "jumprope", "ski", "snowshoe", "skat",
                            "snowboard", "kayak", "canoe", "paddl", "surf", "kite", "danc", "ballet",
                            "cheer", "parkour", "wheelchair", "cardio", "steptraining", "aerobic"]),
    ]

    /// The family a sport label belongs to.
    public static func family(forSport sport: String) -> Family {
        let key = sport.lowercased().filter { $0.isLetter }
        guard !key.isEmpty else { return .unknown }
        for (family, keys) in table where keys.contains(where: key.contains) {
            return family
        }
        return .unknown
    }

    /// Whether a finished session is worth a rating prompt.
    ///
    /// A steady or low-load session qualifies when it was long (`substantialMinutes`), when its
    /// average heart rate reached `substantialReserve` of the reserve, or when there is no heart rate
    /// to judge it by — nothing else then describes its load. `restingHR` / `maxHR` default to 60 and
    /// the age-free 190 when unknown; they only decide the intensity half of the test.
    public static func isWorthRating(sport: String, durationSeconds: Double, averageHR: Double?,
                                     restingHR: Double?, maxHR: Double?) -> Bool {
        if family(forSport: sport).alwaysWorthRating { return true }
        if durationSeconds.isFinite, durationSeconds >= substantialMinutes * 60 { return true }
        guard let averageHR, averageHR.isFinite, averageHR > 0 else { return true }
        let resting = min(100, max(35, restingHR ?? 60))
        let maximum = max(resting + 20, maxHR ?? 190)
        return (averageHR - resting) / (maximum - resting) >= substantialReserve
    }
}
