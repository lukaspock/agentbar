import SwiftUI

/// Inline replacement of the old "Agent user…" alert: host status and the setup hint as a card in the notch panel.
struct AgentUserStatusCard: View {
    let onClose: () -> Void
    @State private var snapshot = Snapshot()

    private struct Snapshot {
        var available = false
        var detail = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Agent user").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(AgentUser.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            HStack(spacing: 8) {
                Circle().fill(snapshot.available ? Color(red: 0.45, green: 0.85, blue: 0.70) : BarTheme.needsInput)
                    .frame(width: 8, height: 8)
                Text("Host: \(snapshot.detail)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.available {
                Text("Sessions started as \(AgentUser.name) run under a separate macOS user.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("To set it up, review and run \(AgentUser.setupScript) yourself in Terminal (it needs an administrator; use --dry-run first). AgentBar does not run it for you.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08)))
        .onAppear { refresh() }
        .task {
            // The host channel connects in the background: keep the card current while it is open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refresh()
            }
        }
    }

    private func refresh() {
        let client = AgentHostHub.shared.client
        let next = Snapshot(available: client.isAvailable, detail: client.statusDetail)
        if next.available != snapshot.available || next.detail != snapshot.detail { snapshot = next }
    }
}
