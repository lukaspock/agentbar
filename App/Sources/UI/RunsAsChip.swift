import SwiftUI

/// Small "agentbar" marker. Shown only for sessions the app itself started with the agent target
/// (see `ChatBackend.runsAsAgent`), never derived from agent-provided text.
struct RunsAsChip: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.fill").font(.system(size: 8, weight: .semibold))
            Text("as \(AgentUser.name)").font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Color(red: 0.62, green: 0.80, blue: 1.0))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color(red: 0.35, green: 0.60, blue: 1.0).opacity(0.18)))
        .help("Runs as the \(AgentUser.name) user (started by AgentBar)")
    }
}
