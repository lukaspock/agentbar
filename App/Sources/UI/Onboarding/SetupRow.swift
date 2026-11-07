import SwiftUI
import AgentBarCore

extension SetupStep {
    var onboardingTitle: String {
        switch self {
        case .agentUser: return "Agent user"
        case .hostBinary: return "Background helper"
        case .cli: return "agentbar command"
        case .claudeCLI: return "Claude CLI"
        case .claudeToken: return "Claude sign-in"
        case .claudeHooks: return "Claude Code hooks"
        case .codexHooks: return "Codex hooks"
        case .autostart: return "Launch at login"
        case .notifications: return "Notifications"
        }
    }

    var onboardingDetail: String {
        switch self {
        case .agentUser: return "A separate macOS account for agents"
        case .hostBinary: return "Runs agent sessions for that account"
        case .cli: return "Command line tool for your terminal"
        case .claudeCLI: return "Needed to run Claude Code"
        case .claudeToken: return "Gives agents access to your account"
        case .claudeHooks: return "Reports session status to the bar"
        case .codexHooks: return "Reports Codex status to the bar"
        case .autostart: return "Starts AgentBar when you log in"
        case .notifications: return "Alerts when an agent needs you"
        }
    }
}

/// Small "Details ▸" style toggle with content below.
struct DisclosureLink<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(reduceMotion ? nil : BarTheme.spring) { open.toggle() } } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                    Text(title).font(.system(size: 11))
                }
                .foregroundStyle(OnboardingStyle.secondaryText)
            }
            .buttonStyle(.plain)
            if open { content }
        }
    }
}

/// One progress line: blob status dot, title, detail, error with Retry/Skip, optional disclosures.
struct SetupRow: View {
    let step: SetupStep
    let state: OnboardingModel.RowState
    /// Hooks change text for "View changes" (only used for the hooks steps).
    var diff: String? = nil
    var canAct = true
    var onRetry: () -> Void = {}
    var onSkip: () -> Void = {}

    private var blobState: SessionState {
        if state.skipped { return .idle }
        switch state.status {
        case .done: return .done
        case .running: return .working
        case .failed: return .error
        case .missing, .notApplicable: return .idle
        }
    }

    private var failure: String? {
        if case .failed(let m) = state.status, !state.skipped { return m }
        return nil
    }

    private var detail: String {
        if state.skipped { return "Skipped" }
        if case .running = state.status, let last = state.log.last { return last }
        if case .notApplicable(let m) = state.status, step.isOptional { return m }
        return step.onboardingDetail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BlobView(state: blobState, kind: .circle, size: 18, tint: blobState == .done ? OnboardingStyle.ok : nil, seed: step.rawValue)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.onboardingTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(OnboardingStyle.primaryText)
                Text(detail).font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondaryText).lineLimit(1)
                if let failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(BarTheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !state.log.isEmpty {
                    DisclosureLink(title: "Details") {
                        Text(state.log.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(OnboardingStyle.secondaryText)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let diff, !diff.isEmpty, step == .claudeHooks {
                    DisclosureLink(title: "View changes") {
                        ScrollView(.horizontal) {
                            Text(diff).font(.system(size: 10, design: .monospaced)).foregroundStyle(OnboardingStyle.secondaryText)
                                .textSelection(.enabled).padding(8)
                        }
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
                    }
                }
            }
            Spacer(minLength: 8)
            if failure != nil {
                HStack(spacing: 10) {
                    Button("Retry", action: onRetry).buttonStyle(.plain).foregroundStyle(OnboardingStyle.primaryText)
                    Button("Skip", action: onSkip).buttonStyle(.plain).foregroundStyle(OnboardingStyle.tertiaryText)
                }
                .font(.system(size: 12, weight: .medium)).disabled(!canAct)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}
