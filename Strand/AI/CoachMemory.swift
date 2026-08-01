import Foundation

/// The coach's persistent memory: small facts about the user (goals, injuries, preferences) that the
/// model saves via the `remember_fact` tool, plus the user's own free-text training goal. Facts carry a
/// category and an importance so the coach can inject the RELEVANT ones per question (pinned facts always,
/// the rest ranked by keyword overlap + recency) instead of dumping all of them into every prompt.
/// UserDefaults-backed JSON (small, non-secret, on-device only). Own file: merge-clean against upstream.
@MainActor
final class CoachMemory: ObservableObject {

    /// What a fact is about — used for grouping in the UI and light prioritisation. `injury`/`goal` are
    /// the kinds a coach should never forget, so they default to being surfaced.
    enum Category: String, Codable, CaseIterable {
        case goal, injury, preference, physiology, schedule, other

        var label: String {
            switch self {
            case .goal:       return "Goal"
            case .injury:     return "Injury"
            case .preference: return "Preference"
            case .physiology: return "Physiology"
            case .schedule:   return "Schedule"
            case .other:      return "Other"
            }
        }

        var symbol: String {
            switch self {
            case .goal:       return "target"
            case .injury:     return "bandage"
            case .preference: return "heart"
            case .physiology: return "waveform.path.ecg"
            case .schedule:   return "calendar"
            case .other:      return "note.text"
            }
        }
    }

    /// How strongly a fact should be surfaced. `pinned` facts ride EVERY prompt (injuries, hard
    /// constraints); `normal` facts are injected only when relevant to the question.
    enum Importance: String, Codable { case pinned, normal }

    enum Verification: String, Codable {
        case hypothesis
        case pendingConfirmation
        case confirmed

        var label: String {
            switch self {
            case .hypothesis: return "Hypothesis"
            case .pendingConfirmation: return "Needs confirmation"
            case .confirmed: return "Confirmed"
            }
        }
    }

    enum Sensitivity: String, Codable {
        case ordinary
        case health
    }

    enum Source: String, Codable {
        case user
        case coachTool
        case conversationSummary
        case legacy
    }

    struct Evidence: Codable, Equatable {
        let source: Source
        let referenceID: String?
        let recordedAt: Date
    }

    struct Revision: Codable, Equatable {
        let previousText: String
        let changedAt: Date
    }

    struct MemoryFact: Identifiable, Codable, Equatable {
        let id: UUID
        var text: String
        var category: Category
        var importance: Importance
        var createdAt: Date
        var verification: Verification
        var sensitivity: Sensitivity
        var source: Source
        var validFrom: Date
        var validUntil: Date?
        var evidenceCount: Int
        var evidence: [Evidence]
        var revisions: [Revision]

        init(id: UUID = UUID(),
             text: String,
             category: Category = .other,
             importance: Importance = .normal,
             createdAt: Date = Date(),
             verification: Verification = .confirmed,
             sensitivity: Sensitivity = .ordinary,
             source: Source = .user,
             validFrom: Date? = nil,
             validUntil: Date? = nil,
             evidenceCount: Int = 1,
             evidence: [Evidence]? = nil,
             revisions: [Revision] = []) {
            self.id = id
            self.text = text
            self.category = category
            self.importance = importance
            self.createdAt = createdAt
            self.verification = verification
            self.sensitivity = sensitivity
            self.source = source
            self.validFrom = validFrom ?? createdAt
            self.validUntil = validUntil
            self.evidenceCount = max(1, evidenceCount)
            self.evidence = evidence ?? [
                Evidence(source: source, referenceID: nil, recordedAt: createdAt)
            ]
            self.revisions = revisions
        }

        // Back-compat: facts saved before category/importance existed decode with sensible defaults, so
        // an upgrade never drops the user's memory.
        private enum CodingKeys: String, CodingKey {
            case id, text, category, importance, createdAt, verification, sensitivity
            case source, validFrom, validUntil, evidenceCount, evidence, revisions
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            text = try c.decode(String.self, forKey: .text)
            category = try c.decodeIfPresent(Category.self, forKey: .category) ?? .other
            importance = try c.decodeIfPresent(Importance.self, forKey: .importance) ?? .normal
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            verification = try c.decodeIfPresent(Verification.self, forKey: .verification) ?? .confirmed
            sensitivity = try c.decodeIfPresent(Sensitivity.self, forKey: .sensitivity) ?? .ordinary
            source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .legacy
            validFrom = try c.decodeIfPresent(Date.self, forKey: .validFrom) ?? createdAt
            validUntil = try c.decodeIfPresent(Date.self, forKey: .validUntil)
            evidenceCount = max(1, try c.decodeIfPresent(Int.self, forKey: .evidenceCount) ?? 1)
            evidence = try c.decodeIfPresent([Evidence].self, forKey: .evidence)
                ?? [Evidence(source: source, referenceID: nil, recordedAt: createdAt)]
            revisions = try c.decodeIfPresent([Revision].self, forKey: .revisions) ?? []
        }
    }

    /// One shared instance so the engine (writer via tool) and the settings card (viewer/editor)
    /// observe the same `@Published` state.
    static let shared = CoachMemory()

    /// Saved facts, newest first. Capped so the store can't grow without bound.
    @Published private(set) var facts: [MemoryFact] { didSet { saveFacts() } }

    private let d: UserDefaults
    private let updatesSemanticIndex: Bool
    private static let factsKey = "ai.memory.facts"
    /// Hard cap on stored facts — old ones fall off the end when the model over-remembers.
    static let maxFacts = 40

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        self.updatesSemanticIndex = defaults === UserDefaults.standard
        self.facts = (try? JSONDecoder().decode([MemoryFact].self,
                                                from: defaults.data(forKey: Self.factsKey) ?? Data())) ?? []
    }

    // MARK: - Mutations

    /// Add a fact (newest first), enforcing the cap. Near-duplicates (same normalised text, or one text
    /// fully contained in the other) UPDATE the existing fact in place instead of stacking a rephrasing,
    /// so the 40-slot budget isn't wasted. Returns false only when the text is empty.
    ///
    /// Only matched against facts in the SAME category — dedup is category-scoped (see `isNearDuplicate`),
    /// so an "injury" restating a knee problem never collapses onto an unrelated "preference".
    ///
    /// `confirmedByUser` is what makes an `.injury` / `.goal` / `.physiology` fact usable at all. Those
    /// categories are saved `.pendingConfirmation`, and `pinnedBlock` admits only `.confirmed` facts — so
    /// without a way to say "the user stated this themselves", every health fact the coach saves is
    /// permanently barred from the block it was pinned for. It applies on the near-duplicate path too:
    /// the user confirming a fact the coach already holds arrives here as a restatement, and that path
    /// used to leave `verification` untouched, which is exactly why a "yes, that's right" could never
    /// land.
    @discardableResult
    func add(_ text: String,
             category: Category = .other,
             importance: Importance = .normal,
             source: Source = .user,
             referenceID: String? = nil,
             confirmedByUser: Bool = false,
             validUntil: Date? = nil) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let key = Self.normalize(clean)
        if let idx = facts.firstIndex(where: {
            $0.category == category && Self.isNearDuplicate(Self.normalize($0.text), key, category: category)
        }) {
            // Supersede the near-duplicate: keep its id, refresh text/recency. Importance/verification are
            // never DOWNGRADED by a restatement — a rephrasing of a pinned injury must not quietly demote
            // it out of `pinnedBlock` just because the caller passed a looser importance this time, and an
            // already-confirmed fact must not fall back to a hypothesis because the coach re-inferred it.
            facts[idx].text = clean
            facts[idx].evidenceCount += 1
            facts[idx].evidence.append(Evidence(source: source,
                                                referenceID: referenceID,
                                                recordedAt: Date()))
            if facts[idx].evidence.count > 20 {
                facts[idx].evidence.removeFirst(facts[idx].evidence.count - 20)
            }
            if importance == .pinned { facts[idx].importance = .pinned }
            if confirmedByUser { facts[idx].verification = .confirmed }
            // An expiry is only ever REPLACED by another expiry, never cleared by a restatement that
            // simply didn't mention one — "I still can't run" shouldn't resurrect a fact indefinitely.
            if let validUntil { facts[idx].validUntil = validUntil }
            facts[idx].createdAt = Date()
            facts.sort { $0.createdAt > $1.createdAt }
            return true
        }
        let needsConfirmation = category == .injury || category == .physiology || category == .goal
        let verification: Verification
        if confirmedByUser {
            verification = .confirmed
        } else {
            verification = needsConfirmation ? .pendingConfirmation : .hypothesis
        }
        let fact = MemoryFact(
            text: clean,
            category: category,
            importance: importance,
            verification: verification,
            sensitivity: (category == .injury || category == .physiology) ? .health : .ordinary,
            source: source,
            validUntil: validUntil,
            evidence: [Evidence(source: source, referenceID: referenceID, recordedAt: Date())]
        )
        var updated = [fact] + facts
        if updated.count > Self.maxFacts, let dropIdx = Self.evictionIndex(in: updated) {
            updated.remove(at: dropIdx)
        }
        facts = updated
        return true
    }

    /// Which fact to drop when the cap is reached, in order of what costs least to lose:
    ///
    /// 1. the oldest **expired** fact — it is already invisible to every retrieval path, so it is
    ///    occupying a slot while contributing nothing (before `validUntil` was ever written, this arm
    ///    could not fire and dead facts sat in the store forever);
    /// 2. otherwise the oldest **non-pinned** fact, so a pinned injury or hard constraint never falls
    ///    off merely for being old;
    /// 3. otherwise the oldest fact — everything is pinned and unexpired, and something has to give.
    ///
    /// Pure and static so the eviction order can be pinned by a test without a `UserDefaults` fixture.
    /// `facts` is newest-first, so "oldest" is the LAST match.
    static func evictionIndex(in facts: [MemoryFact], now: Date = Date()) -> Int? {
        guard !facts.isEmpty else { return nil }
        if let expired = facts.lastIndex(where: { $0.validUntil.map { $0 < now } ?? false }) {
            return expired
        }
        return facts.lastIndex(where: { $0.importance != .pinned }) ?? facts.indices.last
    }

    /// Edit a fact's text in place (a model correction, or the user editing in settings).
    @discardableResult
    func update(_ id: UUID, text: String, confirmedByUser: Bool = false) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let idx = facts.firstIndex(where: { $0.id == id }) else { return false }
        if facts[idx].text != clean {
            facts[idx].revisions.append(Revision(previousText: facts[idx].text, changedAt: Date()))
            if facts[idx].revisions.count > 20 {
                facts[idx].revisions.removeFirst(facts[idx].revisions.count - 20)
            }
        }
        facts[idx].text = clean
        if confirmedByUser { facts[idx].verification = .confirmed }
        return true
    }

    func confirm(_ id: UUID) {
        guard let idx = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[idx].verification = .confirmed
        facts[idx].evidenceCount += 1
    }

    /// Find a fact whose text near-matches `query` (for the model's forget/update-by-text tools). The
    /// tools don't supply a category to match against, so this uses the STRICTEST thresholds (`.injury`'s)
    /// regardless of the candidate's own category — handing `forget_fact`/`update_fact` the wrong fact is
    /// worse than it occasionally not finding the right one.
    func firstMatch(_ query: String) -> MemoryFact? {
        let key = Self.normalize(query)
        guard !key.isEmpty else { return nil }
        return facts.first(where: { Self.isNearDuplicate(Self.normalize($0.text), key, category: .injury) })
    }

    func remove(_ id: UUID) {
        facts = facts.filter { $0.id != id }
    }

    func clearAll() {
        facts = []
    }

    // MARK: - Retrieval

    /// Pinned facts — the block that rides EVERY prompt because it's always relevant. The training goal
    /// used to live here as a bare sentence; it now has its own structured model (`CoachGoal`) and is
    /// injected by `AICoachEngine.goalBlock` with its dates, remaining change and pace verdict.
    var pinnedBlock: String {
        var lines: [String] = []
        let now = Date()
        let pinned = facts.filter {
            $0.importance == .pinned && $0.verification == .confirmed
                && $0.validFrom <= now
                && ($0.validUntil == nil || $0.validUntil! >= now)
        }
        if !pinned.isEmpty {
            lines.append("ALWAYS-RELEVANT FACTS ABOUT THE USER (rely on these every time):")
            for f in pinned { lines.append("• \(f.text)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The `limit` facts most relevant to `query`: pinned first, then normal facts ranked by keyword
    /// overlap with the question, decayed by age. Injected into the question's context so the coach gets
    /// the pertinent memory without every prompt carrying all 40 facts.
    func relevantFacts(for query: String, limit: Int, now: Date = Date()) -> [MemoryFact] {
        let active = facts.filter {
            $0.validFrom <= now && ($0.validUntil == nil || $0.validUntil! >= now)
        }
        let pinned = active.filter { $0.importance == .pinned && $0.verification == .confirmed }
        let rest = active.filter { !($0.importance == .pinned && $0.verification == .confirmed) }
        let qTokens = Self.tokens(query)
        let ranked = rest
            .map { fact -> (MemoryFact, Double) in (fact, Self.relevanceScore(fact, qTokens, now: now)) }
            // A ranking is not a reason to disclose: when no meaningful token overlaps, a normal fact
            // must stay local. Without this filter the newest eight facts would leak into every request
            // merely because zero-score ties still have an order.
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
        // Always take pinned; fill the remaining budget with the highest-ranked normal facts.
        let normalBudget = max(0, limit - pinned.count)
        return pinned + Array(ranked.prefix(normalBudget))
    }

    /// Keyword overlap decayed by age, so an old fact's relevance actually fades instead of only ever
    /// breaking a tie — see `relevanceScore` for the exact formula. A fact with ZERO overlap still scores
    /// zero regardless of age — decay only discounts an already-relevant fact, it never manufactures
    /// relevance for an unrelated one. A real half-life, not a hard cutoff, so nothing vanishes abruptly;
    /// a fact that's still clearly relevant (high overlap) stays competitive well past 30 days.
    static let recencyHalfLifeDays: Double = 30

    /// Not `private` so `CoachMemoryRankingTests` can pin the decay formula directly, without needing to
    /// seed a whole `CoachMemory`/`UserDefaults` fixture just to reach it through `relevantFacts`.
    static func relevanceScore(_ fact: MemoryFact, _ qTokens: Set<String>, now: Date) -> Double {
        let overlap = Double(Self.overlap(Self.tokens(fact.text), qTokens))
        guard overlap > 0 else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(fact.createdAt) / 86_400)
        // ln(2) makes this an actual half-life: the score is exactly half at ageDays == recencyHalfLifeDays,
        // not merely "smaller" — plain exp(-ageDays/halfLife) decays to ~0.37 there, not 0.5.
        return overlap * exp(-log(2) * ageDays / recencyHalfLifeDays)
    }

    /// The relevant-facts block for a specific question (used by the context builder). Empty when there's
    /// nothing beyond what `pinnedBlock` already carries.
    ///
    /// `alreadyInContext` is the context this block is about to be appended to. Two independent memory
    /// retrievers run per turn — this keyword ranking, and the on-device semantic index, which stores the
    /// same facts as `[Memory]` documents — so without the check the same sentence goes on the wire
    /// twice, once bare and once behind a "Confirmed memory:" prefix. Deduplication belongs here rather
    /// than in the semantic path because this block is the one that is appended last.
    func relevantBlock(for query: String, limit: Int, alreadyInContext: String = "") -> String {
        let ranked = relevantFacts(for: query, limit: limit).filter { $0.importance != .pinned }
        let picked = Self.factsNotAlreadyInContext(ranked, context: alreadyInContext)
        guard !picked.isEmpty else { return "" }
        var lines = ["POSSIBLY-RELEVANT FACTS ABOUT THE USER (from memory):"]
        for f in picked {
            switch f.verification {
            case .confirmed:
                lines.append("• \(f.text)")
            case .hypothesis:
                lines.append("• [hypothesis; \(f.evidenceCount) observation(s)] \(f.text)")
            case .pendingConfirmation:
                lines.append("• [unconfirmed — ask the user before relying on this] \(f.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Parse a model- or user-supplied `yyyy-MM-dd` expiry into the INSTANT that day ends locally.
    /// Retrieval tests `validUntil >= now`, so parsing to midnight would expire a fact at the very start
    /// of the day the user named as its last valid one. Anything malformed yields nil, which means "no
    /// expiry" — a fact that never expires is a far smaller error than one that silently vanishes
    /// because a model wrote the date in a format we don't read.
    static func expiryDate(from raw: String?, calendar: Calendar = .current) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: raw) else { return nil }
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else {
            return nil
        }
        return next.addingTimeInterval(-1)
    }

    /// The facts whose text does not already appear in `context`, compared on the normalised form so a
    /// difference in punctuation or casing doesn't defeat the match. An empty context filters nothing.
    /// Pure and static: the dedup rule is pinned by a test without an engine or a semantic index.
    static func factsNotAlreadyInContext(_ facts: [MemoryFact], context: String) -> [MemoryFact] {
        let haystack = normalize(context)
        guard !haystack.isEmpty else { return facts }
        return facts.filter { fact in
            let needle = normalize(fact.text)
            return needle.isEmpty || !haystack.contains(needle)
        }
    }

    // MARK: - Text helpers

    /// Very small stopword set so keyword overlap keys on the meaningful words.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with", "my", "me", "i",
        "is", "are", "was", "were", "be", "do", "does", "did", "how", "what", "why", "when", "should",
        "about", "your", "you", "this", "that", "it", "at", "as", "so", "if", "can", "will", "im"
    ]

    /// Lowercased, punctuation-stripped word tokens ≥ 3 chars, stopwords removed.
    static func tokens(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let parts = lowered.split { !$0.isLetter && !$0.isNumber }
        return Set(parts.map(String.init).filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Int { a.intersection(b).count }

    /// A normalised form for duplicate detection: lowercased, only letters/numbers, single-spaced.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let kept = lowered.map { ($0.isLetter || $0.isNumber || $0 == " ") ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Conservative local classifier for facts distilled by the optional summariser, whose legacy
    /// output format carries text but no category. False negatives remain ordinary hypotheses; obvious
    /// health/injury and goal language is promoted to a category that requires user confirmation.
    ///
    /// The term lists cover every language the app ships (en, de, es, fr, it, pt, ru, zh). The
    /// summariser writes in the user's own language, so an English-and-German-only list meant that for
    /// six of the nine locales EVERY distilled fact fell through to `.preference` — a reported injury
    /// then carried neither the health sensitivity nor the pending-confirmation flag its category
    /// exists to set. Matching is substring-based over the normalised text, which is what makes the
    /// Chinese terms work without word boundaries.
    static func inferredCategory(for text: String) -> Category {
        let normalized = normalize(text)
        let injuryTerms = [
            "injury", "injured", "pain", "ache", "sore", "diagnosed", "surgery",
            "verletzung", "verletzt", "schmerz", "operation", "entzündung",
            "lesión", "lesion", "dolor", "lastimad", "cirugía", "cirugia",
            "blessure", "blessé", "blesse", "douleur", "chirurgie",
            "infortunio", "lesione", "dolore", "chirurgia",
            "lesão", "lesao", "dores", "machucad",
            "травма", "болит", "операц",
            "受伤", "疼痛", "损伤", "手術", "手术",
        ]
        if injuryTerms.contains(where: normalized.contains) { return .injury }
        let physiologyTerms = [
            "allergy", "condition", "medication", "blood test", "lab result",
            "allergie", "erkrankung", "medikament", "blutwert", "laborwert",
            "alergia", "medicación", "medicacion", "análisis de sangre", "analisis de sangre",
            "médicament", "medicament", "analyse de sang", "maladie",
            "allergia", "farmaco", "esame del sangue", "malattia",
            "medicamento", "exame de sangue", "doença", "doenca",
            "аллерг", "лекарств", "анализ крови", "заболевание",
            "过敏", "药物", "藥物", "血液检查", "血液檢查",
        ]
        if physiologyTerms.contains(where: normalized.contains) { return .physiology }
        let goalTerms = [
            "goal", "target", "aims to", "training for", "ziel", "möchte erreichen",
            "trainiert für",
            "objetivo", "entrenando para",
            "objectif", "s entraîne pour", "s entraine pour",
            "obiettivo", "si allena per",
            "treinando para",
            "цель", "готовится к",
            "目标", "目標", "备战", "備戰",
        ]
        if goalTerms.contains(where: normalized.contains) { return .goal }
        let scheduleTerms = [
            "schedule", "weekday", "weekend", "morning", "evening",
            "zeitplan", "wochentag", "wochenende", "morgens", "abends",
            "horario", "entre semana", "fin de semana", "mañana", "manana", "tarde", "noche",
            "emploi du temps", "semaine", "week end", "matin", "soir",
            "orario", "settimana", "fine settimana", "mattina", "di sera",
            "horário", "fim de semana", "manhã", "manha", "noite",
            "расписан", "будни", "выходн", "утром", "вечером",
            "日程", "工作日", "周末", "週末", "早上", "晚上",
        ]
        if scheduleTerms.contains(where: normalized.contains) { return .schedule }
        return .preference
    }

    /// How much of the smaller fact's meaningful vocabulary must appear in the other before the two are
    /// treated as the same fact reworded, for callers with no category context (kept as the loose,
    /// catch-all default so existing direct callers of `hasDuplicateTokenOverlap(_:_:)` are unaffected).
    static let duplicateTokenOverlap: Double = 0.8
    /// Below this many meaningful tokens, overlap is meaningless ("knee pain" vs "knee sore" would
    /// collapse), so short facts fall back to the string tests alone.
    static let minTokensForOverlapMatch = 3

    /// Per-category dedup strictness: (token-overlap ratio, containment length-ratio, min meaningful
    /// tokens for the overlap test to apply). `.injury`/`.goal` need near-medical precision — "ACL tear"
    /// and "meniscus tear" share a lot of vocabulary but are different facts, so a wrong collapse there is
    /// the costliest kind of data loss. `.physiology` sits in between. Casual restatements (`.preference`,
    /// `.schedule`, `.other`) can collapse more readily — losing a rephrasing there costs nothing.
    static func thresholds(for category: Category) -> (overlap: Double, containment: Double, minTokens: Int) {
        switch category {
        case .injury, .goal:
            return (0.85, 0.80, 5)
        case .physiology:
            return (0.75, 0.70, 4)
        case .preference, .schedule, .other:
            return (0.65, 0.65, 3)
        }
    }

    /// Two normalised strings are near-duplicates when equal, when one contains the other and they're
    /// close in length (a rephrasing/extension of the same fact), or when their meaningful words almost
    /// entirely overlap — at the strictness `category` calls for (see `thresholds(for:)`).
    ///
    /// That last test is why re-summarising a chat no longer stacks memory: a cheap model asked twice
    /// about the same conversation says the same thing in different words ("Runs three times a week" vs
    /// "The user runs 3x per week"), which the string tests miss entirely and which used to land as a
    /// second fact against the 40-slot cap.
    static func isNearDuplicate(_ a: String, _ b: String, category: Category) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        let t = thresholds(for: category)
        // Only treat containment as duplicate when the shorter is a substantial part of the longer, so
        // "knee" doesn't collapse an unrelated longer fact that merely contains the word.
        if longer.contains(shorter), Double(shorter.count) / Double(longer.count) >= t.containment {
            return true
        }
        return hasDuplicateTokenOverlap(a, b, minTokens: t.minTokens, overlapThreshold: t.overlap)
    }

    /// Back-compat overload for callers with no category context — uses the loosest, catch-all (`.other`)
    /// thresholds.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        isNearDuplicate(a, b, category: .other)
    }

    /// The token-overlap arm of `isNearDuplicate`: near-total shared vocabulary, measured against the
    /// SMALLER set so a fact that merely adds detail to a known one still collapses onto it.
    static func hasDuplicateTokenOverlap(_ a: String, _ b: String,
                                         minTokens: Int = minTokensForOverlapMatch,
                                         overlapThreshold: Double = duplicateTokenOverlap) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard ta.count >= minTokens, tb.count >= minTokens else { return false }
        let shared = ta.intersection(tb).count
        let smaller = min(ta.count, tb.count)
        return Double(shared) / Double(smaller) >= overlapThreshold
    }

    private func saveFacts() {
        if let data = try? JSONEncoder().encode(facts) { d.set(data, forKey: Self.factsKey) }
        if updatesSemanticIndex {
            let snapshot = facts
            Task { await CoachSemanticMemory.shared.memoryFactsChanged(snapshot) }
        }
    }
}
