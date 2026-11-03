import Foundation

/// Where a new chat session runs. App-side knowledge only: this is what the user chose in the dialog.
enum ChatTarget: Equatable {
    case local(directory: URL)
    /// Runs as the dedicated agent user via the host; `workspace` is a folder name below the agent's work directory.
    case agent(workspace: String)
}

/// The small seam to the privileged agent-user host (implemented by the Core host client later; `FakeAgentHostClient` for
/// previews/tests). Everything the UI knows about "agentbar" comes through here, never from agent output.
@MainActor
protocol AgentHostClient: AnyObject {
    /// Host reachable and set up right now (cheap, synchronous; the dialog and menu read it when they open).
    var isAvailable: Bool { get }
    /// One line for the "Agent user…" status, e.g. "reachable" / "not set up". Never contains secrets.
    var statusDetail: String { get }
    /// Existing workspace folder names (not paths).
    func workspaces() async throws -> [String]
    /// Creates a workspace (the host validates again) and returns its final name.
    func makeWorkspace(name: String) async throws -> String
}

/// Holds the active host client. Default: unavailable, so "agentbar" stays disabled until the real client is wired.
@MainActor
final class AgentHostHub {
    static let shared = AgentHostHub()
    var client: AgentHostClient = UnavailableAgentHostClient()
}

enum AgentHostError: LocalizedError {
    case unavailable
    case invalidName
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The agent user host is not available."
        case .invalidName: return "Workspace names may use letters, digits, dot, dash and underscore (max 64, no leading dot)."
        }
    }
}

enum AgentUser {
    static let name = "agentbar"
    static let setupScript = "Scripts/setup-agent-user.sh"

    /// Client-side pre-check only; the host validates authoritatively.
    static func isValidWorkspaceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy { ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)))) || "._-".unicodeScalars.contains($0) }
    }
}

/// Default until the real client is wired in: nothing is reachable.
@MainActor
final class UnavailableAgentHostClient: AgentHostClient {
    var isAvailable: Bool { false }
    var statusDetail: String { "not set up" }
    func workspaces() async throws -> [String] { throw AgentHostError.unavailable }
    func makeWorkspace(name: String) async throws -> String { throw AgentHostError.unavailable }
}

/// In-memory host for previews, tests and screenshots.
@MainActor
final class FakeAgentHostClient: AgentHostClient {
    var isAvailable: Bool
    var statusDetail: String { isAvailable ? "reachable (demo)" : "not set up" }
    private(set) var names: [String]
    private let latency: UInt64

    init(available: Bool = true, workspaces: [String] = ["agentbar-app", "notes", "sandbox"], latencyMs: UInt64 = 250) {
        isAvailable = available
        names = workspaces
        latency = latencyMs * 1_000_000
    }

    func workspaces() async throws -> [String] {
        try await Task.sleep(nanoseconds: latency)
        guard isAvailable else { throw AgentHostError.unavailable }
        return names
    }

    func makeWorkspace(name: String) async throws -> String {
        try await Task.sleep(nanoseconds: latency)
        guard isAvailable else { throw AgentHostError.unavailable }
        guard AgentUser.isValidWorkspaceName(name) else { throw AgentHostError.invalidName }
        if !names.contains(name) { names.append(name) }
        return name
    }
}
