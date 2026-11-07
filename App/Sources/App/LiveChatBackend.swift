import Foundation
import AgentBarCore

/// Real chat backend: one `ChatSession` (claude stream-json process) per chat session in the bar.
@MainActor
final class LiveChatBackend: ChatBackend {
    private let store: SessionStore
    private var chats: [String: ChatSession] = [:]
    /// Sessions this app started with the agent target. App knowledge only, never derived from agent output.
    private var agentIds: Set<String> = []
    /// Set once the transport exists; nil means no agent host in this process.
    var hostClient: HostClient?

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

    func runsAsAgent(sessionId: String) -> Bool { agentIds.contains(sessionId) }

    /// Forks a terminal (hook) session into a new chat session: always local, as the owner (the transcript lives in the
    /// owner's ~/.claude), never without `--fork-session` (enforced by `ChatConfig.launchSpec`). The terminal session
    /// itself is not touched; failures become an error entry in the source session.
    func continueInPanel(from session: AgentSession, completion: @escaping (Result<String, Error>) -> Void) {
        func fail(_ message: String) {
            store.apply(.log(sessionId: session.id, entry: HistoryEntry(kind: .error, text: "Continue in panel failed: " + message)))
            completion(.failure(StartError(message: message)))
        }
        guard session.canContinueInPanel, let cwd = session.workingDirectory else {
            fail("This session has no usable id or working directory."); return
        }
        guard let claude = ChatConfig.locateClaude() else {
            fail("The claude CLI was not found (~/.local/bin, /opt/homebrew/bin, /usr/local/bin)."); return
        }
        let base = String(session.name.prefix(AgentBarLimits.maxNameLength - 7))
        let config = ChatConfig(executable: claude, workingDirectory: URL(fileURLWithPath: cwd, isDirectory: true),
                                name: base + " (fork)",
                                resume: ChatResume(sessionId: session.id, sourceName: session.name))
        let chat = ChatSession(config: config, store: store)
        do { try chat.start() } catch {
            switch error {
            case ChatError.invalidConfig(let why): fail("Cannot continue here: \(why).")
            case ChatError.spawnFailed(let why): fail("Could not start claude: \(why)")
            default: fail("Could not start claude: \(error.localizedDescription)")
            }
            return
        }
        chats[chat.sessionId] = chat
        completion(.success(chat.sessionId))
    }

    func startSession(target: ChatTarget, completion: @escaping (Result<String, Error>) -> Void) {
        switch target {
        case .local(let directory):
            startSession(directory: directory, completion: completion)
        case .agent(let workspace):
            guard AgentUser.isValidWorkspaceName(workspace) else { completion(.failure(AgentHostError.invalidName)); return }
            guard let host = hostClient, host.isConnected else {
                completion(.failure(StartError(message: "The agent host is not connected. Check \"Agent user…\" in the menu."))); return
            }
            let config = ChatConfig.remote(workspace: workspace, workspaceRoot: host.info?.workspaceRoot)
            let chat = ChatSession(config: config, store: store, processFactory: host.processFactory)
            do { try chat.start() } catch { completion(.failure(error)); return }   // core releases the reservation on failure
            chats[chat.sessionId] = chat
            agentIds.insert(chat.sessionId)
            completion(.success(chat.sessionId))
        }
    }
}
