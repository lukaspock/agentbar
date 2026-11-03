import Foundation
import AgentBarCore

/// Real `AgentHostClient`: wraps the Core `HostClient` (the long-lived channel of the `agentbar-host` process).
/// Availability is a cached copy of the channel state, refreshed from `onStateChange` on the main actor.
@MainActor
final class LiveAgentHostClient: AgentHostClient {
    private let host: HostClient
    private var cached: HostClient.State

    init(host: HostClient) {
        self.host = host
        cached = host.state
        host.onStateChange = { [weak self] state in
            Task { @MainActor in self?.cached = state }
        }
    }

    var isAvailable: Bool { if case .connected = cached { return true }; return false }

    var statusDetail: String {
        switch cached {
        case .disconnected: return "not connected (agentbar-host is not running or not set up)"
        case .connected(let info): return "connected as \(info.user)"
        }
    }

    func workspaces() async throws -> [String] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String], Error>) in
            host.listWorkspaces { result in
                switch result {
                case .success(let items): c.resume(returning: items.sorted { $0.mtime > $1.mtime }.map(\.name))
                case .failure(let e): c.resume(throwing: Self.map(e))
                }
            }
        }
    }

    func makeWorkspace(name: String) async throws -> String {
        guard AgentUser.isValidWorkspaceName(name) else { throw AgentHostError.invalidName }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            host.createWorkspace(name: name) { result in
                switch result {
                case .success(let n): c.resume(returning: n)
                case .failure(let e): c.resume(throwing: Self.map(e))
                }
            }
        }
    }

    private nonisolated static func map(_ e: HostError) -> Error {
        switch e {
        case .notConnected, .disconnected: return AgentHostError.unavailable
        case .timeout: return LiveChatBackend.StartError(message: "The agent host did not answer in time.")
        case .host(let m): return LiveChatBackend.StartError(message: "Agent host: \(m)")
        }
    }
}
