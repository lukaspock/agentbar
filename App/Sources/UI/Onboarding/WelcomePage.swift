import SwiftUI
import AgentBarCore

/// Page 1: the sleeping mascot wakes up on "Get started"; the user picks the run mode.
struct WelcomePage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 28) {
            OnboardingHeader(title: "Welcome to AgentBar", sentence: "Your coding agents, always one glance away.") {
                MascotView(appearance: model.mascot, size: 120, since: model.mascotSince)
                    .frame(width: 140, height: 140)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $model.useAgentUser) {
                    Text("Use a separate agent user").font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.switch)
                Text(model.useAgentUser
                     ? "Agents run in their own macOS account. Asks for your admin password once."
                     : "Agents run as you, locally. No admin password needed.")
                    .font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: 380, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingStyle.card))
            .disabled(model.busy)
        }
        .padding(.horizontal, 28)
    }
}
