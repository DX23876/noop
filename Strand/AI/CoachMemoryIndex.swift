import Foundation
import SemanticMemory
import WhoopStore

enum CoachSemanticRetrievalMode: String {
    case semantic
    case keywordFallback
    case unavailable
}

struct CoachSemanticRetrieval {
    let context: String
    let mode: CoachSemanticRetrievalMode
}

/// The coach's long-term memory index (Android parity plan, Coach extraction). Apple answers it with
/// `CoachSemanticMemory` and its bundled embedding model; a host without that model (the Android test build)
/// uses `NoCoachMemoryIndex`, and the coach then answers without recalled context. Each target that links the
/// coach defines `coachMemoryIndex()`, the shared index the stores report changes to.
@MainActor
protocol CoachMemoryIndex: AnyObject {
    func allowedScopes(for consent: ToolConsent) -> Set<SemanticConsentScope>
    func prewarm(conversations: [CoachConversation], journalEntries: [JournalEntry],
                 allowedScopes: Set<SemanticConsentScope>) async
    func performMaintenance(conversations: [CoachConversation], journalEntries: [JournalEntry],
                            allowedScopes: Set<SemanticConsentScope>, limit: Int) async
    func reconcile(conversations: [CoachConversation], journalEntries: [JournalEntry],
                   allowedScopes: Set<SemanticConsentScope>) async
    func startManualIndexing()
    func unload() async
    func conversationsChanged(_ conversations: [CoachConversation]) async
    func memoryFactsChanged(_ facts: [CoachMemory.MemoryFact]) async
    func retrieve(question: String, conversations: [CoachConversation], journalEntries: [JournalEntry],
                  allowedScopes: Set<SemanticConsentScope>) async -> CoachSemanticRetrieval
}

/// No memory index: nothing is indexed and nothing is recalled.
@MainActor
final class NoCoachMemoryIndex: CoachMemoryIndex {
    func allowedScopes(for consent: ToolConsent) -> Set<SemanticConsentScope> { [] }
    func prewarm(conversations: [CoachConversation], journalEntries: [JournalEntry],
                 allowedScopes: Set<SemanticConsentScope>) async {}
    func performMaintenance(conversations: [CoachConversation], journalEntries: [JournalEntry],
                            allowedScopes: Set<SemanticConsentScope>, limit: Int) async {}
    func reconcile(conversations: [CoachConversation], journalEntries: [JournalEntry],
                   allowedScopes: Set<SemanticConsentScope>) async {}
    func startManualIndexing() {}
    func unload() async {}
    func conversationsChanged(_ conversations: [CoachConversation]) async {}
    func memoryFactsChanged(_ facts: [CoachMemory.MemoryFact]) async {}
    func retrieve(question: String, conversations: [CoachConversation], journalEntries: [JournalEntry],
                  allowedScopes: Set<SemanticConsentScope>) async -> CoachSemanticRetrieval {
        CoachSemanticRetrieval(context: "", mode: .unavailable)
    }
}
