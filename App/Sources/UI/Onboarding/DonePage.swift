import SwiftUI
import AgentBarCore

/// Page 4: the mascot celebrates (done blob with afterglow), checklist, two switches, link to mascot settings.
struct DonePage: View {
    @ObservedObject var model: OnboardingModel
    @State private var since = Date()

    var body: some View {
        VStack(spacing: 14) {
            OnboardingHeader(title: "You're all set", sentence: "Agents show up in the bar as soon as they start.") {
                BlobView(state: .done, kind: model.mascotKind, size: 60, tint: model.mascotColor, stateSince: since, seed: "done")
                    .frame(width: 84, height: 84)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(checklist, id: \.self) { checkRow($0) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: 380)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingStyle.card))

            VStack(spacing: 8) {
                toggleRow("Launch at login", isOn: $model.autostart)
                toggleRow("Notify me when an agent needs input", isOn: $model.notifications)
            }
            .frame(maxWidth: 380)

            Button("Customize mascot") { model.actions.customizeMascot() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondaryText)
        }
        .padding(.horizontal, 28)
        .task { await model.loadStateIfNeeded(); model.applyDoneToggles() }
        .onAppear { since = Date() }
    }

    private var checklist: [SetupStep] {
        model.visibleSteps.filter { $0 != .autostart && $0 != .notifications }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(OnboardingStyle.primaryText)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func checkRow(_ step: SetupStep) -> some View {
        let r = model.row(step)
        let ok: Bool = { if case .done = r.status { return true } else { return false } }()
        return HStack(spacing: 7) {
            Image(systemName: ok ? "checkmark.circle.fill" : (r.skipped ? "minus.circle" : "exclamationmark.circle.fill"))
                .foregroundStyle(ok ? OnboardingStyle.ok : (r.skipped ? OnboardingStyle.tertiaryText : BarTheme.error))
                .font(.system(size: 12))
            Text(step.onboardingTitle).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(ok ? OnboardingStyle.primaryText : OnboardingStyle.secondaryText)
            if r.skipped && !ok { Text("Skipped").font(.system(size: 10)).foregroundStyle(OnboardingStyle.tertiaryText) }
        }
        .accessibilityElement(children: .combine)
    }
}
