import SwiftUI
import AgentBarCore

/// Page 2 (agent user only): browser sign-in before the admin step. The token is never shown, logged or stored here.
struct LoginPage: View {
    @ObservedObject var model: OnboardingModel
    @State private var showPaste = false
    @State private var pasted = ""
    @FocusState private var pasteFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            OnboardingHeader(title: "Sign in with Claude", sentence: "One approval in your browser lets agents use your account.") {
                BlobView(state: heroState, kind: model.mascotKind, size: 72, tint: model.mascotColor, seed: "login")
                    .frame(width: 84, height: 84)
            }
            VStack(spacing: 14) {
                switch model.login {
                case .idle, .failed:
                    Button { model.signIn() } label: {
                        Label("Sign in with Claude", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(OnboardingButtonStyle())
                    if case .failed(let m) = model.login {
                        Text(m).font(.system(size: 11)).foregroundStyle(BarTheme.error)
                    }
                case .waiting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for browser approval…").font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondaryText)
                    }
                    Button("Cancel") { model.cancelSignIn() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OnboardingStyle.tertiaryText)
                case .signedIn:
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(OnboardingStyle.ok)
                }
                if model.login != .signedIn { fallback }
            }
            .frame(maxWidth: 340)
        }
        .padding(.horizontal, 28)
        .animation(reduceMotion ? nil : BarTheme.spring, value: showPaste)
    }

    private var heroState: SessionState {
        switch model.login {
        case .idle: return .idle
        case .waiting: return .needsInput
        case .signedIn: return .done
        case .failed: return .error
        }
    }

    @ViewBuilder
    private var fallback: some View {
        if showPaste {
            HStack(spacing: 8) {
                SecureField("Paste token", text: $pasted)
                    .textFieldStyle(.roundedBorder).focused($pasteFocused)
                    .onSubmit(submit)
                Button("Use", action: submit).disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else {
            Button("Paste token instead") { showPaste = true; pasteFocused = true }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondaryText)
        }
        Button("Skip this step") { Task { await model.skipLogin() } }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OnboardingStyle.tertiaryText)
    }

    private func submit() {
        let token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        pasted = ""   // cleared at once; the token only travels through the closure
        guard !token.isEmpty else { return }
        showPaste = false
        Task { await model.submitToken(token) }
    }
}
