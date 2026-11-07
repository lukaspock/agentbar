import Foundation

/// Minimal key-value persistence (UserDefaults suite in production). Only non-secret onboarding flags go here.
public protocol SetupKeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

public final class UserDefaultsSetupStore: SetupKeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

public final class InMemorySetupStore: SetupKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func string(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ value: String?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
}

public enum SetupError: Error, Equatable, CustomStringConvertible, Sendable {
    case noAction(SetupStep)
    case noAdminHandler
    case noTokenAcquirer
    public var description: String {
        switch self {
        case .noAction(let s): return "no action configured for \(s.rawValue)"
        case .noAdminHandler: return "no admin handler configured"
        case .noTokenAcquirer: return "no token acquirer configured"
        }
    }
}

/// Drives the setup: every run starts with `check()` (idempotent), failures set `.failed` and independent steps
/// still run. Persists only `onboarding.completedVersion` and `onboarding.skippedSteps`.
public actor SetupRunner: SetupRunning {
    public static let completedVersionKey = "onboarding.completedVersion"
    public static let skippedStepsKey = "onboarding.skippedSteps"

    private let probes: [SetupStep: SetupProbe]
    private let actions: [SetupStep: SetupAction]
    private let adminBlock: SetupAdminBlock?
    private let tokenAcquirer: SetupTokenAcquirer?
    private let store: SetupKeyValueStore
    private var useAgentUser: Bool
    private var statuses: [SetupStep: StepStatus] = [:]

    public init(probes: [SetupProbe], actions: [SetupAction], adminBlock: SetupAdminBlock? = nil,
                tokenAcquirer: SetupTokenAcquirer? = nil, store: SetupKeyValueStore, useAgentUser: Bool = true) {
        self.probes = Dictionary(probes.map { ($0.step, $0) }, uniquingKeysWith: { $1 })
        self.actions = Dictionary(actions.map { ($0.step, $0) }, uniquingKeysWith: { $1 })
        self.adminBlock = adminBlock; self.tokenAcquirer = tokenAcquirer
        self.store = store; self.useAgentUser = useAgentUser
    }

    // MARK: persistence

    public var completedVersion: String? { store.string(forKey: Self.completedVersionKey) }
    public func markCompleted(version: String) { store.set(version, forKey: Self.completedVersionKey) }

    public var skippedSteps: Set<SetupStep> {
        Set((store.string(forKey: Self.skippedStepsKey) ?? "").split(separator: ",").compactMap { SetupStep(rawValue: String($0)) })
    }
    public func skip(_ step: SetupStep) { writeSkipped(skippedSteps.union([step])) }
    public func unskip(_ step: SetupStep) { writeSkipped(skippedSteps.subtracting([step])) }
    private func writeSkipped(_ s: Set<SetupStep>) {
        store.set(s.isEmpty ? nil : s.map(\.rawValue).sorted().joined(separator: ","), forKey: Self.skippedStepsKey)
    }

    public func setUseAgentUser(_ on: Bool) { useAgentUser = on }

    // MARK: state

    private func options(unskipping step: SetupStep? = nil) -> SetupOptions {
        var skipped = skippedSteps
        if let step { skipped.remove(step) }
        return SetupOptions(useAgentUser: useAgentUser, skippedSteps: skipped)
    }

    public func state() -> SetupState { SetupState(statuses: statuses, options: options()) }

    /// Re-runs every applicable probe (steps that are not applicable in the current mode are not probed).
    @discardableResult
    public func refresh() async -> SetupState {
        for step in SetupStep.allCases { await check(step) }
        return state()
    }

    private func check(_ step: SetupStep) async {
        if !useAgentUser, SetupState.agentOnly.contains(step) { statuses[step] = .notApplicable("local mode"); return }
        guard let p = probes[step] else { statuses[step] = .notApplicable("no probe configured"); return }
        statuses[step] = Self.normalized(step, await p.check())
    }

    /// Optional steps (notifications) never stay `failed`: the problem is shown as a neutral "off".
    private static func normalized(_ step: SetupStep, _ s: StepStatus) -> StepStatus {
        if step.isOptional, case .failed(let m) = s { return .notApplicable(m) }
        return s
    }

    // MARK: running

    public func runAll(progress: @escaping @Sendable (SetupEvent) -> Void = { _ in }) async -> SetupState {
        await refresh()
        await perform(SetupState(statuses: statuses, options: options()).plan, progress: progress)
        return state()
    }

    public func run(step: SetupStep, progress: @escaping @Sendable (SetupEvent) -> Void = { _ in }) async -> SetupState {
        await check(step)
        if step == .claudeToken { await check(.agentUser); await check(.claudeCLI) }
        let plan = SetupState(statuses: statuses, options: options(unskipping: step)).plan.filter { $0.step == step }
        await perform(plan, progress: progress)
        return state()
    }

    private func perform(_ items: [SetupPlanItem], progress: @escaping @Sendable (SetupEvent) -> Void) async {
        var tokenBlocked = false
        var adminHandled = false
        for item in items {
            switch item.phase {
            case .run:
                await runAction(item.step, progress: progress)
            case .acquire:
                if let missing = SetupState.dependencies(of: .claudeToken).first(where: { $0 == .claudeCLI && statuses[$0] != .done }) {
                    finish(.claudeToken, .failed("requires \(missing.rawValue)"), progress); tokenBlocked = true
                } else { tokenBlocked = !(await acquireToken(progress)) }
            case .admin:
                guard !adminHandled else { continue }
                adminHandled = true
                var steps = items.filter { $0.phase == .admin }.map(\.step)
                if tokenBlocked { steps.removeAll { $0 == .claudeToken } }
                await runAdmin(steps, progress: progress)
            }
        }
    }

    private func finish(_ step: SetupStep, _ status: StepStatus, _ progress: @Sendable (SetupEvent) -> Void) {
        statuses[step] = status
        progress(.finished(step, status))
    }

    /// Runs the action, then re-checks with the probe: success is what the probe says, not what the action claims.
    private func runAction(_ step: SetupStep, progress: @escaping @Sendable (SetupEvent) -> Void) async {
        statuses[step] = .running; progress(.started(step))
        guard let action = actions[step] else { finish(step, .failed(SetupError.noAction(step).description), progress); return }
        var failure: String?
        do { try await action.run(progress: { progress(.message(step, $0)) }) } catch { failure = "\(error)" }
        await verify(step, failure: failure, progress)
    }

    /// `installerSucceeded`: the admin block ran through without error for this step. The token is then root-verified in
    /// place, so a probe that merely could not ask the host ("unknown") must not turn the row red.
    private func verify(_ step: SetupStep, failure: String?, installerSucceeded: Bool = false,
                        _ progress: @Sendable (SetupEvent) -> Void) async {
        guard let probe = probes[step] else { finish(step, failure.map { .failed($0) } ?? .done, progress); return }
        let s = Self.normalized(step, await probe.check())
        switch s {
        case .done, .notApplicable: finish(step, s, progress)
        case .failed(let m):
            if installerSucceeded, failure == nil, s.isTokenStateUnknown { finish(step, .done, progress) }
            else { finish(step, .failed(failure ?? m), progress) }
        case .missing, .running:
            if step.isOptional { finish(step, .notApplicable(failure ?? "Not available in this build"), progress) }
            else { finish(step, .failed(failure ?? "still not set up after running"), progress) }
        }
    }

    /// Phase 1 of the token step. Returns false when it failed (token status is then `.failed`).
    private func acquireToken(_ progress: @escaping @Sendable (SetupEvent) -> Void) async -> Bool {
        statuses[.claudeToken] = .running; progress(.started(.claudeToken))
        guard let acq = tokenAcquirer else { finish(.claudeToken, .failed(SetupError.noTokenAcquirer.description), progress); return false }
        do { try await acq.acquire(progress: { progress(.message(.claudeToken, $0)) }); return true }
        catch { finish(.claudeToken, .failed("\(error)"), progress); return false }
    }

    private func runAdmin(_ steps: [SetupStep], progress: @escaping @Sendable (SetupEvent) -> Void) async {
        guard !steps.isEmpty else { return }
        for s in steps where s != .claudeToken { statuses[s] = .running; progress(.started(s)) }
        if steps.contains(.claudeToken) { statuses[.claudeToken] = .running }
        var failure: String?
        if let admin = adminBlock {
            do { try await admin.run(steps: steps, progress: { msg in steps.forEach { progress(.message($0, msg)) } }) }
            catch { failure = "\(error)" }
        } else { failure = SetupError.noAdminHandler.description }
        for s in steps { await verify(s, failure: failure, installerSucceeded: s == .claudeToken, progress) }
        // The token cannot be valid without the agent user, whatever its own probe says.
        if steps.contains(.claudeToken), statuses[.claudeToken] == .done, statuses[.agentUser] != .done {
            finish(.claudeToken, .failed("requires \(SetupStep.agentUser.rawValue)"), progress)
        }
    }
}

// MARK: - Preview fake

/// In-memory runner for UI previews and UI tests: no probes, no system access. Steps listed in `failing` end `.failed`.
public actor FakeSetupRunner: SetupRunning {
    private var statuses: [SetupStep: StepStatus]
    private var options: SetupOptions
    private let failing: Set<SetupStep>
    private let stepDelay: Duration
    public private(set) var completedVersion: String?

    public init(statuses: [SetupStep: StepStatus] = [:], options: SetupOptions = SetupOptions(),
                failing: Set<SetupStep> = [], stepDelay: Duration = .zero) {
        self.statuses = SetupState(statuses: statuses, options: options).statuses
        self.options = options; self.failing = failing; self.stepDelay = stepDelay
    }

    public func state() -> SetupState { SetupState(statuses: statuses, options: options) }
    public func refresh() -> SetupState { state() }
    public func markCompleted(version: String) { completedVersion = version }

    public func runAll(progress: @escaping @Sendable (SetupEvent) -> Void) async -> SetupState {
        var seen = Set<SetupStep>()
        for item in state().plan where seen.insert(item.step).inserted { await simulate(item.step, progress) }
        return state()
    }

    public func run(step: SetupStep, progress: @escaping @Sendable (SetupEvent) -> Void) async -> SetupState {
        if state().status(of: step).isOpen { await simulate(step, progress) }
        return state()
    }

    private func simulate(_ step: SetupStep, _ progress: @Sendable (SetupEvent) -> Void) async {
        statuses[step] = .running; progress(.started(step))
        if stepDelay != .zero { try? await Task.sleep(for: stepDelay) }
        let s: StepStatus = failing.contains(step) ? .failed("simulated failure") : .done
        statuses[step] = s; progress(.finished(step, s))
    }
}
