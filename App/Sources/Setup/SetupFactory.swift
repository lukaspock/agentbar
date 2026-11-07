import AppKit
import AgentBarCore

// MARK: - Adapters

/// `SetupTokenInspector` over the host op `tokenstatus` (metadata only; the owner cannot read the agent home).
/// No host connection means the agent user is not running yet, so there is no token to find: reported as absent.
struct HostTokenInspector: SetupTokenInspector {
    let client: HostClient?

    func tokenInfo() async throws -> SetupTokenFileInfo? {
        guard let client else { return nil }
        let result: Result<HostTokenStatus, HostError> = await withCheckedContinuation { cont in
            client.tokenStatus { cont.resume(returning: $0) }
        }
        switch result {
        case .failure(.notConnected), .failure(.disconnected): return nil
        case .failure(let e): throw e
        case .success(let st):
            guard st.present else { return nil }
            let size = Int64(st.size ?? 0)
            guard st.ownerOK, let mode = st.mode else { return SetupTokenFileInfo(mode: 0o777, size: size) }   // reported as unsafe
            return SetupTokenFileInfo(mode: UInt16(mode & 0o7777), size: size)
        }
    }
}

/// The app's admin block: runs `AdminInstaller` with the staged token and ALWAYS discards the staged token afterwards
/// (the installer removes the file as well).
final class OnboardingAdminBlock: SetupAdminBlock, @unchecked Sendable {
    private let acquirer: ClaudeTokenAcquirer

    init(acquirer: ClaudeTokenAcquirer) { self.acquirer = acquirer }

    func run(steps: [SetupStep], progress: @Sendable (String) -> Void) async throws {
        let acquirer = self.acquirer
        let installer = AdminInstaller(tokenFile: { acquirer.stagedTokenPath.map { URL(fileURLWithPath: $0) } })
        defer { acquirer.discardStaged() }
        try await installer.run(steps: steps, progress: progress)
    }
}

/// Thread-safe text holder for the hooks diff captured right before the hooks were written.
final class HooksPreviewBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return text }
    func set(_ t: String?) { lock.lock(); text = t; lock.unlock() }
}

private struct PreviewingHooksAction: SetupAction {
    let step: SetupStep
    let plan: @Sendable () throws -> HookSetup.Plan
    let apply: @Sendable (HookSetup.Plan) throws -> Void
    let box: HooksPreviewBox?
    func run(progress: @Sendable (String) -> Void) async throws {
        let p = try plan()
        if !p.isNoOp { box?.set(p.preview) }
        progress("Installing hooks")
        try apply(p)   // confirm = true: the user started the step and "View changes" shows exactly this diff
    }
}

// MARK: - Production wiring

/// Everything the real onboarding needs, built once. Touches the system only through the probes/actions it creates.
@MainActor
final class ProductionSetup {
    static let useAgentUserKey = "onboarding.useAgentUser"
    static let snoozedUntilKey = "onboarding.snoozedUntil"

    let runner: SetupRunner
    let store: SetupKeyValueStore
    let acquirer = ClaudeTokenAcquirer()
    let version: String
    private let admin: OnboardingAdminBlock
    private let hooksBox = HooksPreviewBox()
    private let claudeSetup: HookSetup
    private let codexSetup: CodexHookSetup

    /// Own UserDefaults suite when `--prefs-file` is used, so test runs never touch the real onboarding flags.
    static func makeStore(prefsFile: URL?) -> SetupKeyValueStore {
        guard let prefsFile else { return UserDefaultsSetupStore(defaults: .standard) }
        let tag = String(prefsFile.standardizedFileURL.path.map { $0.isLetter || $0.isNumber ? $0 : "_" }.suffix(60))
        let name = "com.agentbar.AgentBar.onboarding." + tag
        guard let d = UserDefaults(suiteName: name) else { return InMemorySetupStore() }
        return UserDefaultsSetupStore(defaults: d)
    }

    static var currentVersion: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0" }

    init(hostClient: HostClient?, prefsFile: URL?) {
        let store = Self.makeStore(prefsFile: prefsFile)
        self.store = store
        version = Self.currentVersion
        let paths = SetupPaths()
        let fs = POSIXSetupFileSystem()
        let proc = FoundationSetupProcessRunner()
        let cli = HookSetup.locateCLI() ?? paths.cliBinary
        claudeSetup = HookSetup(agentbarPath: cli)
        codexSetup = CodexHookSetup(agentbarPath: cli)
        let claude = claudeSetup, codex = codexSetup, box = hooksBox
        admin = OnboardingAdminBlock(acquirer: acquirer)
        let loginItem = LoginItemController()

        let probes: [SetupProbe] = [
            AgentUserProbe(paths: paths, fileSystem: fs, runner: proc),
            RootBinaryProbe(step: .hostBinary, path: paths.hostBinary, fileSystem: fs),
            RootBinaryProbe(step: .cli, path: paths.cliBinary, fileSystem: fs),
            ClaudeCLIProbe(candidates: paths.claudeCandidates, fileSystem: fs, runner: proc),
            ClaudeTokenProbe(inspector: HostTokenInspector(client: hostClient)),
            ClaudeHooksProbe(setup: claude),
            CodexHooksProbe(setup: codex, detectionPaths: paths.codexDetectionPaths, fileSystem: fs),
            AutostartProbe(control: loginItem),
            NotificationsProbe(auth: NotificationPermission()),
        ]
        let actions: [SetupAction] = [
            ClosureSetupAction(step: .claudeCLI) { _ in
                throw SetupActionError("Claude Code is not installed. Install it from claude.com/claude-code, then retry.")
            },
            PreviewingHooksAction(step: .claudeHooks, plan: { try claude.planInstall() },
                                  apply: { try claude.apply($0, confirm: { _ in true }) }, box: box),
            PreviewingHooksAction(step: .codexHooks, plan: { try codex.planInstall() },
                                  apply: { try codex.apply($0, confirm: { _ in true }) }, box: nil),
            ClosureSetupAction(step: .autostart) { _ in
                do { try loginItem.register() } catch LoginItemController.LoginItemError.requiresApproval {
                    loginItem.openSystemSettings()
                    throw LoginItemController.LoginItemError.requiresApproval
                }
            },
            ClosureSetupAction(step: .notifications) { _ in _ = try await NotificationPermission().requestAuthorization() },
        ]
        let useAgent = store.string(forKey: Self.useAgentUserKey) != "0"
        runner = SetupRunner(probes: probes, actions: actions, adminBlock: admin, tokenAcquirer: acquirer,
                             store: store, useAgentUser: useAgent)
    }

    var snoozedUntil: Date? { store.string(forKey: Self.snoozedUntilKey).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }

    func onboardingActions() -> OnboardingActions {
        let runner = runner, store = store, acquirer = acquirer, box = hooksBox
        let claude = claudeSetup, version = version
        let loginItem = LoginItemController()
        var a = OnboardingActions()
        a.useAgentUser = store.string(forKey: Self.useAgentUserKey) != "0"
        a.setUseAgentUser = { on in
            store.set(on ? "1" : "0", forKey: Self.useAgentUserKey)
            await runner.setUseAgentUser(on)
        }
        a.signIn = { try await acquirer.acquire(progress: { _ in }) }
        a.submitToken = { token in try acquirer.acquire(manualToken: token) }
        a.skipStep = { await runner.skip($0) }
        a.hooksDiff = {
            if let t = box.value { return t }
            guard let plan = try? claude.planInstall(), !plan.isNoOp else { return nil }
            return plan.preview
        }
        a.setAutostart = { on in
            do { if on { try loginItem.register() } else { try loginItem.unregister() } }
            catch LoginItemController.LoginItemError.requiresApproval { loginItem.openSystemSettings() }
            catch {}
        }
        a.setNotifications = { on in
            guard on else { return }   // authorization can only be revoked in System Settings
            Task { _ = try? await NotificationPermission().requestAuthorization() }
        }
        a.customizeMascot = { SettingsWindowController.show(page: .mascot) }
        a.finish = {
            acquirer.discardStaged()
            store.set(nil, forKey: Self.snoozedUntilKey)
            Task { await runner.markCompleted(version: version) }
        }
        a.later = {
            acquirer.cancel(); acquirer.discardStaged()
            store.set(String(Date().addingTimeInterval(24 * 3600).timeIntervalSince1970), forKey: Self.snoozedUntilKey)
        }
        return a
    }
}

struct SetupActionError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Demo (no system access at all)

enum DemoOnboarding {
    /// `--demo-onboarding welcome|login|setup|done|error` (+ login-waiting, login-failed for screenshots).
    static func make(_ name: String) -> (runner: any SetupRunning, page: OnboardingModel.Page, actions: OnboardingActions) {
        let allDone = Dictionary(uniqueKeysWithValues: SetupStep.allCases.map { ($0, StepStatus.done) })
        var actions = OnboardingActions()
        actions.later = {}
        actions.finish = {}
        switch name {
        case "done":
            return (FakeSetupRunner(statuses: allDone), .done, actions)
        case "error":
            return (FakeSetupRunner(failing: [.hostBinary, .claudeHooks], stepDelay: .milliseconds(500)), .setup, actions)
        case "setup":
            return (FakeSetupRunner(stepDelay: .milliseconds(1200)), .setup, actions)
        case "login", "login-waiting", "login-failed":
            if name == "login-waiting" { actions.demoLoginPhase = .waiting }
            if name == "login-failed" { actions.demoLoginPhase = .failed("Sign-in did not complete.") }
            actions.signIn = {
                if name == "login-failed" { try await Task.sleep(for: .milliseconds(800)); throw SetupActionError("failed") }
                try await Task.sleep(for: .seconds(name == "login-waiting" ? 3600 : 1.5))
            }
            actions.submitToken = { _ in try await Task.sleep(for: .milliseconds(500)) }
            return (FakeSetupRunner(stepDelay: .milliseconds(600)), .login, actions)
        default:
            actions.demoAutoStart = name == "welcome-awake"
            actions.signIn = { try await Task.sleep(for: .seconds(1.5)) }
            return (FakeSetupRunner(stepDelay: .milliseconds(600)), .welcome, actions)
        }
    }
}

// MARK: - Coordinator

/// Single entry point for showing the onboarding: app start, menu "Setup…", Settings.
@MainActor
final class SetupCoordinator {
    static let shared = SetupCoordinator()

    private var options = LaunchOptions.current
    private var hostClient: HostClient?
    private var production: ProductionSetup?

    func configure(options: LaunchOptions, hostClient: HostClient?) {
        self.options = options
        self.hostClient = hostClient
    }

    /// The real runner (lazily built). nil in any demo mode, where nothing may touch the system.
    var runner: (any SetupRunning)? {
        guard !options.demo else { return nil }   // every demo flag: no real system access, not even read-only probes
        return productionSetup().runner
    }

    private func productionSetup() -> ProductionSetup {
        if let production { return production }
        let p = ProductionSetup(hostClient: hostClient, prefsFile: options.prefsFile)
        production = p
        return p
    }

    private var mascot: MascotAppearance { PreferencesHub.shared.store.mascot() }

    /// Opens (or fronts) the onboarding window.
    func show() {
        if options.demo {
            let d = DemoOnboarding.make(options.demoOnboarding ?? "welcome")
            OnboardingWindowController.show(runner: d.runner, mascot: mascot, actions: d.actions, page: d.page)
            return
        }
        let p = productionSetup()
        OnboardingWindowController.show(runner: p.runner, mascot: mascot, actions: p.onboardingActions())
    }

    /// App start: the demo flag always shows; otherwise only when `OnboardingTrigger` says so. Probes are read-only.
    func showAtLaunchIfNeeded() {
        if options.demoOnboarding != nil { show(); return }
        if options.demo { return }
        let p = productionSetup()
        let force = options.onboardingForce
        Task { @MainActor in
            let state = await p.runner.refresh()
            let done = await p.runner.completedVersion
            if OnboardingTrigger.shouldShow(completedVersion: done, currentVersion: p.version, state: state,
                                            force: force, snoozedUntil: p.snoozedUntil) {
                show()
            }
        }
    }
}
