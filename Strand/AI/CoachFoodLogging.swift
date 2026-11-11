import Foundation
import StrandCore
import StrandAnalytics
import WhoopStore

/// Logging a meal by describing or photographing it (decision 2026-11-08). The cheap coach model only names
/// the foods and their amounts; every nutrient comes from the catalogue entry it then picks among the
/// candidates the phone found. Nothing is saved here: the result is a cart the wearer checks first.
/// Shared with Android through the core (`Shared/`).
enum CoachFoodLogging {
    struct Guess: Equatable, Codable {
        var name: String
        var grams: Double
        /// Search words in the catalogue's language, when they differ from `name`.
        var search: String?
    }

    struct Line: Equatable {
        var item: FoodItem
        var grams: Double
        var guess: Guess
    }

    static let identifySystem = """
        You identify the foods in one meal for a nutrition diary. Reply with JSON only, no prose:
        {"foods":[{"name":"...","grams":120,"search":"..."}]}
        - One object per distinct food or drink, the amount in grams (millilitres for drinks count as grams).
        - Estimate a realistic portion when none is given; never zero.
        - "name" in the language the person used; "search" as a plain German food name for the German
          Nutrient Database (for example "Vollkornbrot", "Banane roh", "Milch 3,5 % Fett").
        - Leave out what is not food. Do not give calories or nutrients.
        """

    static let pickSystem = """
        You match diary foods to database entries. For each food choose the index of the entry that is the same
        food in the same state (raw, cooked, dried), or -1 when none fits. Reply with JSON only:
        {"picks":[0, 2, -1]}
        """

    /// The model's foods from its reply; tolerant of a code fence or prose around the JSON.
    static func parseGuesses(_ reply: String) -> [Guess] {
        guard let object = jsonObject(in: reply), let foods = object["foods"] as? [[String: Any]] else { return [] }
        return foods.compactMap { food in
            guard let name = (food["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let grams = (food["grams"] as? NSNumber)?.doubleValue, grams.isFinite, grams > 0, grams <= 5_000
            else { return nil }
            let search = (food["search"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Guess(name: name, grams: grams, search: search?.isEmpty == false ? search : nil)
        }
        .prefix(20).map { $0 }
    }

    static func parsePicks(_ reply: String, count: Int) -> [Int]? {
        guard let object = jsonObject(in: reply), let picks = object["picks"] as? [NSNumber], picks.count == count
        else { return nil }
        return picks.map(\.intValue)
    }

    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    /// Candidates for each guess, then the model's pick among them. Without a pick the guess is left out
    /// rather than matched by a word: a wrong food is worse than one the wearer adds by hand.
    static func match(_ guesses: [Guess], store: WhoopStore,
                      pick: (String, String) async -> String?) async -> (lines: [Line], unmatched: [Guess]) {
        var candidates: [[FoodItem]] = []
        for guess in guesses {
            var found = await FoodLibrary.search(store: store, query: guess.search ?? guess.name, limit: 8)
            if found.isEmpty, guess.search != nil { found = await FoodLibrary.search(store: store, query: guess.name, limit: 8) }
            candidates.append(found)
        }
        var prompt = ""
        for (index, guess) in guesses.enumerated() {
            prompt += "Food \(index): \(guess.name)\n"
            for (option, item) in candidates[index].enumerated() {
                prompt += "  \(option): \(item.name)\(item.brand.map { " (\($0))" } ?? "")\n"
            }
        }
        let picks = await pick(pickSystem, prompt).flatMap { parsePicks($0, count: guesses.count) }
        var lines: [Line] = []
        var unmatched: [Guess] = []
        for (index, guess) in guesses.enumerated() {
            if let choice = picks?[index], candidates[index].indices.contains(choice) {
                lines.append(Line(item: candidates[index][choice], grams: guess.grams, guess: guess))
            } else {
                unmatched.append(guess)
            }
        }
        return (lines, unmatched)
    }
}

extension AICoachEngine {
    /// A described or photographed meal as cart lines, or nil when the coach could not answer.
    func foodCart(description: String, imageBase64: String? = nil, mimeType: String = "image/jpeg",
                  store: WhoopStore) async -> (lines: [CoachFoodLogging.Line], unmatched: [CoachFoodLogging.Guess])? {
        let text = description.isEmpty ? "What is in this meal?" : description
        let reply: String?
        if let imageBase64 {
            reply = await cheapCompleteWithImage(system: CoachFoodLogging.identifySystem, text: text,
                                                 imageBase64: imageBase64, mimeType: mimeType)
        } else {
            reply = await cheapComplete(system: CoachFoodLogging.identifySystem, user: text, role: .cardAnalysis)
        }
        guard let reply else { return nil }
        let guesses = CoachFoodLogging.parseGuesses(reply)
        guard !guesses.isEmpty else { return ([], []) }
        return await CoachFoodLogging.match(guesses, store: store) { system, user in
            await self.cheapComplete(system: system, user: user, role: .cardAnalysis)
        }
    }
}
