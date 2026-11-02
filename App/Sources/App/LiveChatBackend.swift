import Foundation
import AgentBarCore

/// Real chat backend: one `ChatSession` (claude stream-json process) per chat session in the bar.
@MainActor
final class LiveChatBackend: ChatBackend {
    private let store: SessionStore
    private var chats: [String: ChatSession] = [:]

    struct StartError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(store: SessionStore) {
        self.store = store
        // Chain, never replace: other agents (computer use) may have installed a stop handler already.
        let previous = store.stopHandler
        store.stopHandler = { [weak self] id in
            previous?(id)
            MainActor.assumeIsolated { self?.chats[id]?.stop() }
        }
    }

    func supportsChat(sessionId: String) -> Bool { chats[sessionId]?.phase == .running }

    func send(_ text: String, sessionId: String) {
        guard let chat = chats[sessionId] else { return }
        do { try chat.send(text: text) } catch {
            store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .error, text: "Send failed: \(error)")))
        }
    }

    func startSession(directory: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let claude = ChatConfig.locateClaude() else {
            completion(.failure(StartError(message: "The claude CLI was not found (~/.local/bin, /opt/homebrew/bin, /usr/local/bin)."))); return
        }
        let chat = ChatSession(config: ChatConfig(executable: claude, workingDirectory: directory), store: store)
        do { try chat.start() } catch { completion(.failure(error)); return }
        chats[chat.sessionId] = chat
        completion(.success(chat.sessionId))
    }
}
