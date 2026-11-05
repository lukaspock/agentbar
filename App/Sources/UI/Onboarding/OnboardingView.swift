import SwiftUI
import AppKit
import AgentBarCore

/// Everything the onboarding needs from the outside. All defaults are no-ops so previews and tests run without wiring.
struct OnboardingActions {
    /// Applies the "separate agent user" choice to the runner (the runner protocol has no setter for it).
    var setUseAgentUser: @MainActor (Bool) async -> Void = { _ in }
    /// Starts the browser sign-in (token phase 1 of the `SetupTokenAcquirer`). Throws when it failed or was declined.
    var signIn: @MainActor () async throws -> Void = {}
    /// Hands a manually pasted token to the app. The UI never keeps, shows or logs it.
    var submitToken: @MainActor (String) async throws -> Void = { _ in }
    /// Persists "skip this step" (`SetupRunner.skip`).
    var skipStep: @MainActor (SetupStep) async -> Void = { _ in }
    /// Text of the hooks change (unified diff) for the "View changes" disclosure; nil = nothing to show.
    var hooksDiff: @MainActor () async -> String? = { nil }
    var setAutostart: @MainActor (Bool) -> Void = { _ in }
    var setNotifications: @MainActor (Bool) -> Void = { _ in }
    var customizeMascot: @MainActor () -> Void = {}
    /// Initial state of the "separate agent user" switch (persisted choice of an earlier run).
    var useAgentUser = true
    /// True when the last admin run found an old login account `agentbar` (needs the user's OK to migrate).
    var migrationPending: @MainActor () -> Bool = { false }
    /// The user agreed to migrate the old account; the next admin run converts it.
    var confirmMigration: @MainActor () -> Void = {}
    /// Demo/screenshot aids (`--demo-onboarding`): start on this login phase / press "Get started" after a moment.
    var demoLoginPhase: OnboardingModel.LoginPhase?
    var demoAutoStart = false
    /// "Done" was pressed (mark onboarding completed here).
    var finish: @MainActor () -> Void = {}
    /// "Later" was pressed or the window was closed before the end.
    var later: @MainActor () -> Void = {}
}

enum OnboardingStyle {
    static let background = Color(red: 0.075, green: 0.075, blue: 0.09)
    static let card = Color.white.opacity(0.055)
    static let ok = Color(red: 0.36, green: 0.86, blue: 0.56)
    static let primaryText = Color.white.opacity(0.95)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.38)
}

@MainActor
final class OnboardingModel: ObservableObject {
    enum Page: Int { case welcome, login, setup, done }
    enum LoginPhase: Equatable { case idle, waiting, signedIn, failed(String) }
    struct RowState: Equatable {
        var status: StepStatus
        var log: [String] = []
        var skipped = false
    }

    /// Display order of all steps; the admin group is agentUser...claudeToken.
    static let order: [SetupStep] = [.claudeCLI, .agentUser, .hostBinary, .cli, .claudeToken, .claudeHooks, .codexHooks, .autostart, .notifications]
    static let adminSteps: [SetupStep] = [.agentUser, .hostBinary, .cli, .claudeToken]

    let runner: any SetupRunning
    let mascot: MascotAppearance
    let actions: OnboardingActions

    @Published var page: Page
    @Published var useAgentUser = true
    @Published private(set) var state: SetupState?
    @Published private(set) var rows: [SetupStep: RowState] = [:]
    @Published var login: LoginPhase = .idle
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var hooksDiff: String?
    @Published private(set) var migrationOffer = false
    /// Welcome mascot: far in the past = asleep, `Date()` = woken up.
    @Published private(set) var mascotSince = Date(timeIntervalSinceNow: -(BarTheme.idleSleepAfter + 600))
    @Published var autostart = true { didSet { if oldValue != autostart { actions.setAutostart(autostart) } } }
    @Published var notifications = true { didSet { if oldValue != notifications { actions.setNotifications(notifications) } } }

    private var setupStarted = false
    private var loginTask: Task<Void, Never>?

    init(runner: any SetupRunning, mascot: MascotAppearance = .standard, actions: OnboardingActions = OnboardingActions(),
         page: Page = .welcome) {
        self.runner = runner; self.mascot = mascot; self.actions = actions; self.page = page
        self.useAgentUser = actions.useAgentUser
        if let p = actions.demoLoginPhase { login = p }
    }

    // MARK: derived

    var pageCount: Int { useAgentUser ? 4 : 3 }
    var pageIndex: Int { page == .welcome ? 0 : (useAgentUser ? page.rawValue : page.rawValue - 1) }

    var visibleSteps: [SetupStep] {
        guard let state else { return [] }
        return Self.order.filter { step in
            if case .notApplicable = state.status(of: step) { return false }
            return true
        }
    }

    func row(_ step: SetupStep) -> RowState {
        var r = rows[step] ?? RowState(status: state?.status(of: step) ?? .missing)
        if state?.options.skippedSteps.contains(step) == true { r.skipped = true }
        return r
    }

    var hasUnresolvedFailure: Bool {
        visibleSteps.contains { if case .failed = row($0).status { return !row($0).skipped } else { return false } }
    }

    var mascotColor: Color { Color(hex: mascot.colorHex) ?? BarTheme.idle }
    var mascotKind: BlobKind { BlobKind(storageName: mascot.bodyKindName) ?? .circle }

    // MARK: welcome

    func getStarted() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        mascotSince = Date()
        await actions.setUseAgentUser(useAgentUser)
        let s = await runner.refresh()
        sync(s)
        try? await Task.sleep(for: .milliseconds(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 250 : 900))   // let the wake-up hop play
        let needsLogin = useAgentUser && s.status(of: .claudeToken).isOpen && !s.options.skippedSteps.contains(.claudeToken)
        page = needsLogin ? .login : .setup
    }

    // MARK: login

    func signIn() {
        guard login != .waiting else { return }
        login = .waiting
        loginTask = Task { [actions] in
            do {
                try await actions.signIn()
                if !Task.isCancelled { login = .signedIn }
            } catch {
                if !Task.isCancelled { login = .failed("Sign-in did not complete.") }
            }
        }
    }

    func cancelSignIn() { loginTask?.cancel(); loginTask = nil; login = .idle }

    /// The caller clears its text field before calling; the token is only passed through.
    func submitToken(_ token: String) async {
        login = .waiting
        do { try await actions.submitToken(token); login = .signedIn }
        catch { login = .failed("That token was not accepted.") }
    }

    func skipLogin() async {
        await actions.skipStep(.claudeToken)
        state = await runner.refresh()
        page = .setup
    }

    func continueFromLogin() { page = .setup }

    // MARK: setup

    func runSetupIfNeeded() async {
        guard !setupStarted else { return }
        setupStarted = true
        if state == nil { sync(await runner.refresh()) }
        await perform { progress in await self.runner.runAll(progress: progress) }
        if !hasUnresolvedFailure, page == .setup {
            try? await Task.sleep(for: .milliseconds(700))
            if page == .setup { page = .done }
        }
    }

    func retry(_ step: SetupStep) async {
        guard !running else { return }
        await perform { progress in await self.runner.run(step: step, progress: progress) }
    }

    func skip(_ step: SetupStep) async {
        await actions.skipStep(step)
        var r = row(step); r.skipped = true; rows[step] = r
    }

    func continueFromSetup() { page = .done }

    /// The user agreed to convert the old `agentbar` account: run everything again with migration on.
    func migrate() async {
        guard !running else { return }
        actions.confirmMigration()
        migrationOffer = false
        await perform { progress in await self.runner.runAll(progress: progress) }
    }

    private func perform(_ body: (@escaping @Sendable (SetupEvent) -> Void) async -> SetupState) async {
        running = true
        let (stream, cont) = AsyncStream<SetupEvent>.makeStream()
        let consumer = Task { @MainActor in for await e in stream { apply(e) } }
        let final = await body { cont.yield($0) }
        cont.finish()
        await consumer.value
        sync(final)
        hooksDiff = await actions.hooksDiff()
        migrationOffer = actions.migrationPending()
        running = false
    }

    private func apply(_ event: SetupEvent) {
        switch event {
        case .started(let s): var r = row(s); r.status = .running; rows[s] = r
        case .message(let s, let m):
            var r = row(s); r.log.append(m); if r.log.count > 60 { r.log.removeFirst() }; rows[s] = r
        case .finished(let s, let st): var r = row(s); r.status = st; rows[s] = r
        }
    }

    private func sync(_ s: SetupState) {
        state = s
        for step in SetupStep.allCases {
            var r = rows[step] ?? RowState(status: s.status(of: step))
            r.status = s.status(of: step)
            rows[step] = r
        }
        if case .done = s.status(of: .autostart) { autostart = true }
        notifications = { if case .done = s.status(of: .notifications) { return true } else { return false } }()
    }

    // MARK: done

    func loadStateIfNeeded() async { if state == nil { sync(await runner.refresh()) } }

    func applyDoneToggles() { actions.setAutostart(autostart); actions.setNotifications(notifications) }
}

// MARK: - Window content

struct OnboardingView: View {
    @StateObject private var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: OnboardingModel) { _model = StateObject(wrappedValue: model) }
    init(runner: any SetupRunning, mascot: MascotAppearance = .standard, actions: OnboardingActions = OnboardingActions(),
         page: OnboardingModel.Page = .welcome) {
        self.init(model: OnboardingModel(runner: runner, mascot: mascot, actions: actions, page: page))
    }

    var body: some View {
        VStack(spacing: 0) {
            dots.padding(.top, 34)
            ZStack {
                switch model.page {
                case .welcome: WelcomePage(model: model).transition(pageTransition)
                case .login: LoginPage(model: model).transition(pageTransition)
                case .setup: SetupProgressPage(model: model).transition(pageTransition)
                case .done: DonePage(model: model).transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: 520, height: 620)
        .focusEffectDisabled()
        .background(OnboardingStyle.background)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : BarTheme.spring, value: model.page)
        .task {
            guard model.actions.demoAutoStart else { return }
            try? await Task.sleep(for: .milliseconds(1200))
            await model.getStarted()
        }
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                              removal: .move(edge: .leading).combined(with: .opacity))
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<model.pageCount, id: \.self) { i in
                Capsule().fill(Color.white.opacity(i == model.pageIndex ? 0.8 : 0.2))
                    .frame(width: i == model.pageIndex ? 16 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : BarTheme.spring, value: model.pageIndex)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack {
            if model.page != .done {
                Button("Later") { model.actions.later() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingStyle.tertiaryText)
                    .disabled(model.running)
            }
            Spacer()
            primaryButton
        }
        .padding(.horizontal, 28).padding(.bottom, 24).padding(.top, 8)
        .transaction { $0.animation = nil }   // the footer button swaps its label without a cross-fade
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.page {
        case .welcome:
            Button("Get started") { Task { await model.getStarted() } }
                .buttonStyle(OnboardingButtonStyle()).disabled(model.busy)
        case .login:
            Button("Continue") { model.continueFromLogin() }
                .buttonStyle(OnboardingButtonStyle()).disabled(model.login != .signedIn)
        case .setup:
            Button(model.running ? "Setting up…" : "Continue") { model.continueFromSetup() }
                .buttonStyle(OnboardingButtonStyle()).disabled(model.running || model.hasUnresolvedFailure)
        case .done:
            Button("Done") { model.actions.finish() }
                .buttonStyle(OnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct OnboardingButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(enabled ? (configuration.isPressed ? 0.75 : 0.92) : 0.25)))
            .contentShape(Capsule())
            .animation(nil, value: configuration.isPressed)
    }
}

/// Shared page head: optional hero, title and the one sentence of the page.
struct OnboardingHeader<Hero: View>: View {
    let title: String
    let sentence: String
    @ViewBuilder var hero: Hero
    var body: some View {
        VStack(spacing: 10) {
            hero
            Text(title).font(.system(size: 24, weight: .semibold)).foregroundStyle(OnboardingStyle.primaryText)
            Text(sentence).font(.system(size: 13)).foregroundStyle(OnboardingStyle.secondaryText)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 380)
    }
}

// MARK: - Previews

@MainActor
private func previewModel(_ page: OnboardingModel.Page, runner: FakeSetupRunner = FakeSetupRunner(stepDelay: .milliseconds(400)),
                          login: OnboardingModel.LoginPhase = .idle) -> OnboardingModel {
    let m = OnboardingModel(runner: runner, page: page)
    m.login = login
    return m
}

#Preview("Welcome") { OnboardingView(model: previewModel(.welcome)) }
#Preview("Login") { OnboardingView(model: previewModel(.login)) }
#Preview("Login waiting") { OnboardingView(model: previewModel(.login, login: .waiting)) }
#Preview("Login failed") { OnboardingView(model: previewModel(.login, login: .failed("Sign-in did not complete."))) }
#Preview("Setup") { OnboardingView(model: previewModel(.setup)) }
#Preview("Setup error") {
    OnboardingView(model: previewModel(.setup, runner: FakeSetupRunner(failing: [.hostBinary, .claudeHooks])))
}
#Preview("Done") { OnboardingView(model: previewModel(.done, runner: FakeSetupRunner(statuses: Dictionary(uniqueKeysWithValues: SetupStep.allCases.map { ($0, StepStatus.done) })))) }
