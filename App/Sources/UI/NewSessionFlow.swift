import SwiftUI
import AppKit
import AgentBarCore

/// State of the inline "New session" flow in the notch panel: Run as, Bot, Project, Start. Pure logic, no windows
/// (the folder dialog is opened by the view through `FolderPicker`), so it stays testable.
@MainActor
final class NewSessionFlowModel: ObservableObject {
    enum RunAs { case me, agent }
    enum Choice: Hashable { case existing(String), new }
    enum Step: Int, CaseIterable {
        case runAs, bot, project, start
        var title: String {
            switch self {
            case .runAs: return "Run as"
            case .bot: return "Bot"
            case .project: return "Project"
            case .start: return "Start"
            }
        }
    }

    // After a step change or a panel size change the start action stays locked for `lock(_:)` seconds (the panel springs
    // into its new size; same idea as the approval click guard).

    let host: AgentHostClient
    let hostAvailable: Bool
    let prefs: PreferencesStore
    @Published private(set) var step: Step = .runAs
    @Published var runAs: RunAs = .me
    @Published var localDirectory: URL?
    @Published var workspaces: [String] = []
    @Published var choice: Choice = .new
    @Published var newName = ""
    /// nil = "No bot" (plain Claude).
    @Published private(set) var botId: String?
    /// Set when a bot default (folder/workspace) was applied or could not be applied.
    @Published private(set) var botNote: String?
    @Published private(set) var projectFromBot = false
    @Published var loading = false
    @Published var busy = false
    @Published var error: String?
    @Published private(set) var locked = true

    var onClose: () -> Void = {}
    var onStarted: (String) -> Void = { _ in }
    private var lockTask: Task<Void, Never>?
    private var workspaceDefaultApplied = false
    /// A bot was chosen (or Run as changed) since the defaults were last applied to the project choice.
    private var botDefaultsPending = false

    init(host: AgentHostClient, prefs: PreferencesStore) {
        self.host = host
        self.prefs = prefs
        hostAvailable = host.isAvailable
        lock()
    }

    var ownerName: String { NSUserName() }
    /// Chat can only start Claude Code, so bots of other agent types are not offered here (they stay in Settings).
    var bots: [Bot] { prefs.bots().filter(isSelectable) }
    var selectedBot: Bot? { botId.flatMap { prefs.bot(id: $0) } }
    var newNameInvalid: Bool { !newName.isEmpty && !AgentUser.isValidWorkspaceName(newName) }

    func isSelectable(_ bot: Bot) -> Bool { bot.agentKind == .claudeCode }

    var projectReady: Bool {
        switch runAs {
        case .me: return localDirectory != nil
        case .agent:
            guard hostAvailable, !loading else { return false }
            if case .existing = choice { return true }
            return AgentUser.isValidWorkspaceName(newName)
        }
    }

    var canAdvance: Bool {
        guard !busy else { return false }
        switch step {
        case .runAs: return runAs == .me || hostAvailable
        case .bot: return true
        case .project: return projectReady
        case .start: return projectReady && !locked
        }
    }

    var primaryTitle: String { step == .start ? "Start session" : "Next" }

    /// "~/Projects/x" or "agentbar · workspace" for the summary.
    var projectSummary: String {
        switch runAs {
        case .me: return localDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen"
        case .agent:
            switch choice {
            case .existing(let n): return "\(AgentUser.name) · \(n)"
            case .new: return "\(AgentUser.name) · \(newName.isEmpty ? "new workspace" : newName) (new)"
            }
        }
    }

    // MARK: click guard

    func lock(_ seconds: TimeInterval = 0.7) {
        locked = true
        lockTask?.cancel()
        lockTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.locked = false }
        }
    }

    // MARK: navigation

    func advance() {
        guard canAdvance else { return }
        switch step {
        case .runAs: go(.bot)
        case .bot: go(.project)
        case .project: go(.start)
        case .start: Task { await start() }
        }
    }

    func back() {
        guard !busy else { return }
        error = nil
        switch step {
        case .runAs: onClose()
        case .bot: go(.runAs)
        case .project: go(.bot)
        case .start: go(.project)
        }
    }

    private func go(_ next: Step) {
        step = next
        error = nil
        lock()
        if next == .project { Task { await prepareProject() } }
    }

    /// Entering the Project step: load the workspaces (agent user), then apply the bot's default once per bot choice.
    private func prepareProject() async {
        if runAs == .agent { await loadWorkspaces() }
        if botDefaultsPending, let bot = selectedBot { applyDefaults(of: bot) }
        botDefaultsPending = false
    }

    func select(_ r: RunAs) {
        if r == .agent && !hostAvailable { return }
        runAs = r
        error = nil
        projectFromBot = false
        botNote = nil
        botDefaultsPending = botId != nil
    }

    func loadWorkspaces() async {
        guard hostAvailable, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            workspaces = try await host.workspaces()
            switch choice {
            case .existing(let n) where !workspaces.contains(n):
                choice = workspaces.first.map { .existing($0) } ?? .new   // deleted meanwhile
            case .new where !workspaceDefaultApplied:
                choice = workspaces.first.map { .existing($0) } ?? .new   // first load: preselect the newest workspace
            default: break                                                // keep what the user chose (also after Back)
            }
            workspaceDefaultApplied = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: bots

    func selectBot(_ id: String?) {
        if let id, let bot = prefs.bot(id: id), !isSelectable(bot) { return }
        botId = id
        botNote = nil
        projectFromBot = false
        botDefaultsPending = id != nil
    }

    /// The bot's default folder/workspace preselects the project (changeable on the Project step).
    private func applyDefaults(of bot: Bot) {
        switch runAs {
        case .me:
            guard let path = bot.defaultFolder else { return }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                localDirectory = URL(fileURLWithPath: path, isDirectory: true)
                projectFromBot = true
            } else {
                botNote = "Default folder of \(bot.name) not found: \((path as NSString).abbreviatingWithTildeInPath)"
            }
        case .agent:
            guard let name = bot.defaultWorkspace else { return }
            if workspaces.contains(name) { choice = .existing(name) } else { choice = .new; newName = name }
            projectFromBot = true
        }
    }

    // MARK: start

    /// Resolves the target, creating a new workspace on the host first when needed.
    func resolveTarget() async -> ChatTarget? {
        switch runAs {
        case .me:
            return localDirectory.map { .local(directory: $0) }
        case .agent:
            do {
                switch choice {
                case .existing(let n): return .agent(workspace: n)
                case .new: return .agent(workspace: try await host.makeWorkspace(name: newName))
                }
            } catch {
                self.error = error.localizedDescription
                return nil
            }
        }
    }

    func start() async {
        guard step == .start, canAdvance, let backend = ChatHub.shared.backend else { return }
        // A bot deleted in Settings while the flow was open: stop instead of silently starting without it.
        if botId != nil, selectedBot == nil {
            botId = nil
            error = "The chosen bot no longer exists. Pick another one."
            return
        }
        busy = true
        error = nil
        guard let target = await resolveTarget() else { busy = false; return }
        let bot = selectedBot
        backend.startSession(target: target) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.busy = false
                switch result {
                case .failure(let e):
                    self.error = e.localizedDescription
                case .success(let id):
                    if let bot {
                        // Name/color/blob first, then the owner-written start prompt as the first message.
                        try? self.prefs.setBot(bot.id, forSession: id)
                        if let first = bot.initialMessage { backend.send(first, sessionId: id) }
                    }
                    self.onStarted(id)
                    self.onClose()
                }
            }
        }
    }

    // MARK: demo / screenshot aid

    func applyDemoPreset(_ o: LaunchOptions) {
        guard o.demoNewChat else { return }
        if o.demoNewChatAgent { select(.agent) }
        if let folder = o.demoFlowFolder { localDirectory = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true) }
        if let name = o.demoFlowBot, let bot = prefs.bots().first(where: { $0.name == name }) { selectBot(bot.id) }
        guard let stepName = o.demoFlowStep else { return }
        let target: Step = ["bot": .bot, "project": .project, "start": .start][stepName] ?? .runAs
        Task {
            if runAs == .agent { await loadWorkspaces() }
            if let n = o.demoFlowNewName { choice = .new; newName = n }
            if target == .project || target == .start { await prepareProject() }
            step = target
            lock()
        }
    }
}

/// The macOS folder dialog: one of the two things that stays a system window.
@MainActor
enum FolderPicker {
    static func choose(title: String, startingAt: URL?) -> URL? {
        let open = NSOpenPanel()
        open.title = title
        open.message = "Choose the working directory for the agent"
        open.prompt = "Choose"
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.directoryURL = startingAt
        open.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)   // above the bar panel
        NSApp.activate(ignoringOtherApps: true)
        let result = open.runModal()
        // Hand the keyboard back to the bar panel (Return/Esc of the flow).
        if let panel = NSApp.windows.first(where: { $0 is BarPanel }) as? BarPanel {
            panel.allowKey = true
            panel.makeKey()
        }
        return result == .OK ? open.url : nil
    }
}

// MARK: - Views

struct NewSessionFlowView: View {
    @ObservedObject var model: NewSessionFlowModel
    @ObservedObject private var prefs = PreferencesHub.shared
    @ObservedObject var barModel: BarViewModel

    var body: some View {
        let _ = prefs.revision
        VStack(alignment: .leading, spacing: 12) {
            header
            ZStack(alignment: .topLeading) {
                switch model.step {
                case .runAs: runAsStep
                case .bot: botStep
                case .project: projectStep
                case .start: startStep
                }
            }
            .id(model.step)
            .transition(.opacity)
            if let e = model.error {
                Text(e).font(.system(size: 11)).foregroundStyle(BarTheme.error).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .animation(BarTheme.spring, value: model.step)
        .animation(BarTheme.spring, value: model.runAs)
        .animation(BarTheme.spring, value: model.choice)
        .animation(BarTheme.spring, value: model.error)
        .padding(.horizontal, 10)
    }

    // MARK: chrome

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.back() } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .help(model.step == .runAs ? "Cancel (Esc)" : "Back (Esc)")
            VStack(alignment: .leading, spacing: 1) {
                Text("New session").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(model.step.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(NewSessionFlowModel.Step.allCases, id: \.rawValue) { s in
                    Capsule().fill(Color.white.opacity(s.rawValue <= model.step.rawValue ? 0.75 : 0.18))
                        .frame(width: s == model.step ? 14 : 6, height: 6)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Return  next   ·   Esc  back").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            Spacer()
            if model.busy || model.loading { ProgressView().controlSize(.small).tint(.white) }
            PillButton(title: model.primaryTitle, style: .primary, enabled: model.canAdvance) { model.advance() }
        }
    }

    // MARK: step 1

    private var runAsStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            option(title: model.ownerName, subtitle: "You, in a folder you choose", selected: model.runAs == .me, enabled: true) {
                model.select(.me)
            }
            option(title: AgentUser.name, subtitle: "Separate macOS user, in a workspace on the host",
                   selected: model.runAs == .agent, enabled: model.hostAvailable) { model.select(.agent) }
            if !model.hostAvailable {
                Text("Agent user not available. Run \(AgentUser.setupScript) in Terminal, then open this flow again. See \"Agent user…\" in the menu.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: step 3

    @ViewBuilder private var projectStep: some View {
        switch model.runAs {
        case .me: localProject
        case .agent: agentProject
        }
    }

    private var localProject: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Working directory").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 8) {
                Text(model.localDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen")
                    .font(.system(size: 12)).foregroundStyle(model.localDirectory == nil ? .white.opacity(0.4) : .white)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                PillButton(title: model.localDirectory == nil ? "Choose…" : "Change…") {
                    if let url = FolderPicker.choose(title: "Working directory", startingAt: model.localDirectory) {
                        model.localDirectory = url
                        model.error = nil
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
            projectNotes
        }
    }

    @ViewBuilder private var projectNotes: some View {
        if model.projectFromBot {
            Text("(from bot) You can change it.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
        if let note = model.botNote {
            Text(note).font(.system(size: 10)).foregroundStyle(BarTheme.needsInput).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var agentProject: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Workspace of \(AgentUser.name)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            ScrollView(.vertical, showsIndicators: model.workspaces.count > 4) {
                VStack(spacing: 4) {
                    ForEach(model.workspaces, id: \.self) { name in
                        option(title: name, subtitle: nil, selected: model.choice == .existing(name), enabled: true, compact: true) {
                            model.choice = .existing(name)
                        }
                    }
                    option(title: "New workspace", subtitle: nil, selected: model.choice == .new, enabled: true, compact: true) {
                        model.choice = .new
                    }
                }
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            if model.choice == .new {
                InlineTextField(text: $model.newName, placeholder: "Workspace name", limit: 64, focusOnAppear: true,
                                onEditing: { barModel.setEditing($0) },
                                onSubmit: { model.advance() }, onCancel: { model.back() })
                    .frame(height: 20)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.10)))
                if model.newNameInvalid {
                    Text("Letters, digits, dot, dash, underscore; max 64; no leading dot.")
                        .font(.system(size: 10)).foregroundStyle(BarTheme.error)
                }
            }
            projectNotes
        }
    }

    // MARK: step 2

    private var botStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which bot should run this session?").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            ScrollView(.vertical, showsIndicators: model.bots.count > 3) {
                VStack(spacing: 4) {
                    botRow(bot: nil)
                    ForEach(model.bots) { botRow(bot: $0) }
                }
            }
            .frame(maxHeight: 190)
            .fixedSize(horizontal: false, vertical: true)
            if model.bots.isEmpty {
                HStack(spacing: 6) {
                    Text("No bots yet.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    Button { SettingsWindowController.show(page: .bots) } label: {
                        Text("Create one in Settings").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                            .underline()
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func botRow(bot: Bot?) -> some View {
        let selected = model.botId == bot?.id
        return Button { model.selectBot(bot?.id) } label: {
            HStack(spacing: 10) {
                if let bot {
                    BlobView(state: .working, kind: BlobKind(storageName: bot.blobKindName) ?? .forSession(bot.id), size: 24,
                             tint: Color(hex: bot.colorHex), seed: bot.id)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "circle.dashed").font(.system(size: 16)).foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot?.name ?? "No bot").font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    Text(botSubtitle(bot)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.18 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func botSubtitle(_ bot: Bot?) -> String {
        guard let bot else { return "Plain Claude, no start prompt" }
        var s = "Claude Code"
        if let skill = PreferenceText.skillCommandName(bot.skill) { s += " · /\(skill)" }
        if let f = bot.defaultFolder { s += " · " + (f as NSString).lastPathComponent }
        else if let w = bot.defaultWorkspace { s += " · \(w)" }
        return s
    }

    // MARK: step 4

    private var startStep: some View {
        VStack(alignment: .leading, spacing: 4) {
            summary("Run as", model.runAs == .me ? model.ownerName : AgentUser.name)
            summary("Project", model.projectSummary + (model.projectFromBot ? " (from bot)" : ""))
            summary("Bot", model.selectedBot?.name ?? "No bot")
            if let bot = model.selectedBot, let first = bot.initialMessage {
                Text("First message: " + String(first.split(whereSeparator: \.isNewline).first ?? "").prefix(80))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    .padding(.leading, 66)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private func summary(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).frame(width: 58, alignment: .leading)
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(2).truncationMode(.middle)
        }
    }

    // MARK: shared

    private func option(title: String, subtitle: String?, selected: Bool, enabled: Bool, compact: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13)).foregroundStyle(selected ? Color.white : .white.opacity(0.4))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, compact ? 6 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.16 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Shared by the menu item and the panel buttons: opens the inline flow in the notch panel.
@MainActor
enum NewChatFlow {
    static func run() { PanelRouter.shared.openNewSession() }
}
