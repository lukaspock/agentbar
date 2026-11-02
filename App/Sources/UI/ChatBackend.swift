import Foundation
import SwiftUI
import AgentBarCore

/// What the UI needs from the chat layer (implemented by the CHAT module; `FakeChatBackend` for demos).
/// The backend logs the user's message itself (history entry kind `.answer`, text "You: <msg>");
/// the UI never adds local entries, so the transcript always shows what the agent really received.
@MainActor
protocol ChatBackend: AnyObject {
    func supportsChat(sessionId: String) -> Bool
    func send(_ text: String, sessionId: String)
    /// Starts a new chat session in `directory` (chosen explicitly by the user). Completion delivers the new session id.
    func startSession(directory: URL, completion: @escaping (Result<String, Error>) -> Void)
}

/// Holds the active chat backend. Views observe it so the input appears as soon as a backend is wired.
@MainActor
final class ChatHub: ObservableObject {
    static let shared = ChatHub()
    @Published var backend: ChatBackend?
    func supportsChat(_ session: AgentSession) -> Bool { backend?.supportsChat(sessionId: session.id) ?? false }
}

/// Message split of the history convention: "You: ..." = user message.
enum ChatLine {
    case user(String)
    case agent(String, HistoryEntry.Kind)

    static func parse(_ e: HistoryEntry) -> ChatLine {
        if e.kind == .answer, e.text.hasPrefix("You: ") { return .user(String(e.text.dropFirst(5))) }
        return .agent(e.text, e.kind)
    }
}

/// Scripted chat for `--demo`: logs the user message, answers after a moment.
@MainActor
final class FakeChatBackend: ChatBackend {
    private weak var store: FakeSessionStore?
    private var chatIds: Set<String>

    init(store: FakeSessionStore, chatIds: Set<String>) { self.store = store; self.chatIds = chatIds }

    func supportsChat(sessionId: String) -> Bool { chatIds.contains(sessionId) }

    func send(_ text: String, sessionId: String) {
        guard let store else { return }
        store.appendHistory(sessionId: sessionId, HistoryEntry(kind: .answer, text: "You: \(text)"), state: .working)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak store] in
            MainActor.assumeIsolated {
                store?.appendHistory(sessionId: sessionId,
                                     HistoryEntry(kind: .action, text: "Got it. I will look at \"\(text.prefix(40))\" next."),
                                     state: .idle)
            }
        }
    }

    func startSession(directory: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let store else { return }
        let id = "chat-" + String(UUID().uuidString.prefix(6)).lowercased()
        chatIds.insert(id)
        store.addSession(AgentSession(id: id, name: directory.lastPathComponent, kind: .claudeCode, state: .idle,
                                      history: [HistoryEntry(kind: .status, text: "Chat started in \(directory.path)")],
                                      supportsStop: true))
        completion(.success(id))
    }
}
