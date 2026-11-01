import Foundation
import AgentBarCore

// Test host for Tests/e2e.sh: store + server in a given dir, no GUI.
// Policy by session id: "auto-*" sessions get approved automatically (respond is called twice on purpose to
// exercise the double-response no-op); everything else stays pending. Writes `state.txt` (pending/sessions).

struct FakeClaude: AgentAdapter {
    var kind: AgentKind { .claudeCode }
    func translate(payload: Data) throws -> [CoreEvent] {
        guard let o = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sid = o["session_id"] as? String, let tool = o["tool_name"] as? String else { throw CocoaError(.coderReadCorrupt) }
        let r = AgentRequest(requestId: UUID().uuidString, type: .approval, text: "Run \(tool)?",
                             options: [.init(id: "allow", label: "Allow"), .init(id: "deny", label: "Deny")],
                             timeoutSeconds: 30, defaultOptionId: "deny")
        return [.ask(sessionId: sid, request: r)]
    }
    func encode(response: AgentResponse, for request: AgentRequest) -> Data {
        Data("{\"decision\":\"\(response.optionId ?? "none")\"}".utf8)
    }
}

@MainActor func run() {
    var dir: String?
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--dir"), i + 1 < a.count { dir = a[i + 1] }
    guard let dir else { FileHandle.standardError.write(Data("usage: agentbar-testhost --dir DIR\n".utf8)); exit(64) }
    let store = SessionStore()
    let server = TransportServer(store: store, adapters: ["claudeCode": FakeClaude()], directory: URL(fileURLWithPath: dir))
    do { try server.start() } catch { FileHandle.standardError.write(Data("start failed: \(error)\n".utf8)); exit(1) }
    let statePath = dir + "/state.txt"
    let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        MainActor.assumeIsolated {
            for s in store.sessions where s.id.hasPrefix("auto-") {
                for r in s.pendingRequests {
                    let resp = AgentResponse(requestId: r.requestId, optionId: r.options.first?.id ?? "allow", text: "hi")
                    store.respond(resp, sessionId: s.id)
                    store.respond(AgentResponse(requestId: r.requestId, optionId: "deny"), sessionId: s.id) // must be ignored
                }
            }
            let line = "pending=\(store.pendingRequestCount) sessions=\(store.sessions.count) aggregate=\(store.aggregateState.rawValue)\n"
            try? line.write(toFile: statePath + ".tmp", atomically: false, encoding: .utf8)
            rename(statePath + ".tmp", statePath)
        }
    }
    _ = timer
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { server.stop() }; exit(0) }
        src.resume()
        sigSources.append(src)
    }
    print("READY"); fflush(stdout)
}

nonisolated(unsafe) var sigSources: [DispatchSourceSignal] = []
MainActor.assumeIsolated { run() }
RunLoop.main.run()
