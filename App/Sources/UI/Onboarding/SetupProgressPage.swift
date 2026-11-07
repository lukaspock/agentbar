import SwiftUI
import AgentBarCore

/// Page 3: progress list. The privileged steps form ONE group so it is clear that the password is asked once.
struct SetupProgressPage: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var adminSteps: [SetupStep] { model.visibleSteps.filter { OnboardingModel.adminSteps.contains($0) } }
    private var otherSteps: [SetupStep] { model.visibleSteps.filter { !OnboardingModel.adminSteps.contains($0) } }
    private var adminPending: Bool {
        adminSteps.contains { if case .done = model.row($0).status { return false } else { return !model.row($0).skipped } }
    }
    private var runningStep: SetupStep? {
        model.visibleSteps.first { if case .running = model.row($0).status { return true } else { return false } }
    }
    private var heroState: SessionState {
        if model.hasUnresolvedFailure { return .error }
        return model.running ? .working : .done
    }

    var body: some View {
        VStack(spacing: 12) {
            OnboardingHeader(title: "Setting things up", sentence: model.hasUnresolvedFailure
                             ? "Something needs attention. Retry it or skip it for now."
                             : "This only takes a moment.") {
                BlobView(state: heroState, kind: model.mascotKind, size: 44, tint: model.mascotColor, seed: "setup")
                    .frame(width: 54, height: 54)
            }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(otherSteps.filter { before($0) }, id: \.self) { rowView($0) }
                    if !adminSteps.isEmpty { adminGroup }
                    ForEach(otherSteps.filter { !before($0) }, id: \.self) { rowView($0) }
                }
                .padding(.horizontal, 28).padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            // Soft fade at both ends: the list is clearly scrollable and never runs into the footer button.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                         .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: runningStep) { _, step in
                guard let step else { return }
                withAnimation(reduceMotion ? nil : BarTheme.spring) { proxy.scrollTo(step, anchor: .center) }
            }
            }
        }
        .padding(.top, 6)
        .animation(reduceMotion ? nil : BarTheme.spring, value: model.visibleSteps)
        .task { await model.runSetupIfNeeded() }
    }

    /// Steps ordered before the admin group (the Claude CLI comes first).
    private func before(_ s: SetupStep) -> Bool { s == .claudeCLI }

    private func rowView(_ step: SetupStep) -> some View {
        SetupRow(step: step, state: model.row(step), diff: model.hooksDiff, canAct: !model.running,
                 onRetry: { Task { await model.retry(step) } }, onSkip: { Task { await model.skip(step) } })
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingStyle.card))
            .id(step)
    }

    private var adminGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("Administrator").font(.system(size: 11, weight: .semibold))
                if adminPending {
                    Text("macOS will ask for your password once").font(.system(size: 11)).foregroundStyle(OnboardingStyle.tertiaryText)
                }
                Spacer()
            }
            .foregroundStyle(OnboardingStyle.secondaryText)
            .padding(.horizontal, 14).padding(.top, 10)
            ForEach(Array(adminSteps.enumerated()), id: \.element) { i, step in
                if i > 0 { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 34) }
                SetupRow(step: step, state: model.row(step), canAct: !model.running,
                         onRetry: { Task { await model.retry(step) } }, onSkip: { Task { await model.skip(step) } })
                    .padding(.horizontal, 14)
                    .id(step)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingStyle.card))
    }
}
