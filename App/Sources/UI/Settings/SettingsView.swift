import SwiftUI
import AgentBarCore

struct SettingsView: View {
    @ObservedObject var hub: PreferencesHub
    @State private var tab: SettingsPage

    init(hub: PreferencesHub, page: SettingsPage) {
        self.hub = hub
        _tab = State(initialValue: page == .theme || page == .mascot || page == .setup ? page : .bots)
        self.initialPage = page
    }

    private let initialPage: SettingsPage

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                ThemeSettingsView(hub: hub).tabItem { Label("Theme", systemImage: "paintpalette") }.tag(SettingsPage.theme)
                BotsSettingsView(hub: hub, openEditorOnAppear: initialPage == .editor)
                    .tabItem { Label("Bots", systemImage: "face.smiling") }.tag(SettingsPage.bots)
                MascotSettingsView(hub: hub).tabItem { Label("Mascot", systemImage: "sparkles") }.tag(SettingsPage.mascot)
                SetupSettingsView().tabItem { Label("Setup", systemImage: "checklist") }.tag(SettingsPage.setup)
            }
            if hub.store.isReadOnly || hub.store.lastSaveError != nil {
                Text(hub.store.isReadOnly ? "The preferences file could not be read or backed up, so changes are not saved."
                                          : "Changes could not be saved: \(hub.store.lastSaveError?.localizedDescription ?? "")")
                    .font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .frame(width: 600, height: 560)
    }
}

// MARK: Theme

private struct ThemeSettingsView: View {
    @ObservedObject var hub: PreferencesHub

    var body: some View {
        let _ = hub.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Palette").font(.headline)
                HStack(spacing: 10) {
                    ForEach(ThemePalette.allCases, id: \.self) { paletteCard($0) }
                }
                Divider()
                Text("Agent types").font(.headline)
                Text("Default color and name for sessions of each type. A bot or a per-session choice wins over these.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(AgentKind.allCases, id: \.self) { AgentDefaultRow(hub: hub, kind: $0) }
            }
            .padding(20)
        }
    }

    private func paletteCard(_ p: ThemePalette) -> some View {
        let selected = hub.store.theme == p
        return Button { hub.store.setTheme(p) } label: {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Array(swatches(p).enumerated()), id: \.offset) { _, hex in
                        BlobView(state: .working, kind: .circle, size: 20, tint: Color(hex: hex), seed: hex)
                    }
                }
                .frame(height: 24)
                VStack(spacing: 1) {
                    Text(p.settingsTitle).font(.system(size: 13, weight: .medium))
                    Text(p.settingsSubtitle).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("\(p.settingsTitle) palette")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Automatic shows sample session tints; the others show the palette color of each agent type.
    private func swatches(_ p: ThemePalette) -> [String] {
        if p == .automatic {
            var seen: [String] = []
            for i in 0..<200 where seen.count < 4 {
                let hex = ThemePalette.legacyTintHex(forSession: "sample-\(i)")
                if !seen.contains(hex) { seen.append(hex) }
            }
            return seen
        }
        return AgentKind.allCases.compactMap { p.defaultColorHex(for: $0) }
    }
}

private struct AgentDefaultRow: View {
    @ObservedObject var hub: PreferencesHub
    let kind: AgentKind
    @State private var error: String?

    var body: some View {
        let def = hub.store.agentDefault(for: kind)
        let themeHex = hub.store.theme.defaultColorHex(for: kind)
        let effective = def.colorHex ?? themeHex
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                BlobView(state: .working, kind: .circle, size: 26,
                         tint: effective.flatMap { Color(hex: $0) } ?? Color(hex: ThemePalette.legacyTintHex(forSession: kind.rawValue)),
                         seed: kind.rawValue)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.settingsTitle).font(.system(size: 13, weight: .medium))
                    Text(def.colorHex != nil ? def.colorHex! : (themeHex != nil ? "Palette color" : "Automatic tint per session"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 130, alignment: .leading)
                ColorPicker("Color", selection: Binding(
                    get: { effective.flatMap { Color(hex: $0) } ?? Color.gray },
                    set: { c in
                        do { try hub.store.setAgentDefaultColor(kind, c.hexString); error = nil }
                        catch let e as PreferencesError { error = e.settingsMessage } catch {}
                    }), supportsOpacity: false)
                    .labelsHidden()
                CommitTextField(placeholder: "Default name", text: def.displayName ?? "", limit: PreferenceText.maxNameLength) {
                    hub.store.setAgentDefaultName(kind, $0.isEmpty ? nil : $0)
                }
                Button("Reset") {
                    hub.store.setAgentDefaultName(kind, nil)
                    try? hub.store.setAgentDefaultColor(kind, nil)
                    error = nil
                }
                .disabled(def.isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

/// Text field that edits a local copy and writes back on return / focus loss, so the store's trimming never fights typing.
struct CommitTextField: View {
    let placeholder: String
    let text: String
    let limit: Int
    let commit: (String) -> Void
    @State private var draft: String = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, f in if !f { save() } }
            .onChange(of: draft) { _, v in if v.count > limit { draft = String(v.prefix(limit)) } }
            .onChange(of: text) { _, v in if !focused { draft = v } }
            .onAppear { if !loaded { draft = text; loaded = true } }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != text { commit(trimmed) }
    }
}

// MARK: Bots

private struct BotEditorTarget: Identifiable {
    let id = UUID()
    let bot: Bot?
}

private struct BotsSettingsView: View {
    @ObservedObject var hub: PreferencesHub
    let openEditorOnAppear: Bool
    @State private var editing: BotEditorTarget?
    @State private var deleting: Bot?

    var body: some View {
        let _ = hub.revision
        let bots = hub.store.bots()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bots").font(.headline)
                Spacer()
                Text(String(bots.count) + " of " + String(PreferencesStore.maxBots)).font(.caption).foregroundStyle(.secondary)
                Button { editing = BotEditorTarget(bot: nil) } label: { Label("New bot", systemImage: "plus") }
            }
            Text("A bot has its own name, color, agent type and start prompt.").font(.caption).foregroundStyle(.secondary)
            if bots.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("No bots yet").font(.system(size: 13, weight: .medium))
                    Text("Create one to give an agent a name, a color and a start prompt.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(bots) { bot in
                        BotRow(bot: bot, onEdit: { editing = BotEditorTarget(bot: bot) }, onDelete: { deleting = bot })
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .sheet(item: $editing) { target in
            BotEditorView(hub: hub, bot: target.bot) { editing = nil }
        }
        .alert("Delete bot?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { bot in
            Button("Delete", role: .destructive) { hub.store.deleteBot(id: bot.id) }
            Button("Cancel", role: .cancel) {}
        } message: { bot in
            Text("\"\(bot.name)\" and its session bindings will be removed.")
        }
        .onAppear {
            if openEditorOnAppear && editing == nil { editing = BotEditorTarget(bot: hub.store.bots().first) }
        }
    }
}

private struct BotRow: View {
    let bot: Bot
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BlobView(state: .working, kind: BlobKind(storageName: bot.blobKindName) ?? BlobKind.forSession(bot.id), size: 26,
                     tint: Color(hex: bot.colorHex), seed: bot.id)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Button("Edit", action: onEdit)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Delete bot")
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        let first = bot.startPrompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "No start prompt"
        let place = bot.defaultFolder.map { " · " + ($0 as NSString).abbreviatingWithTildeInPath } ?? bot.defaultWorkspace.map { " · \($0)" } ?? ""
        return "\(bot.agentKind.settingsTitle)\(place) · \(first)"
    }
}

// MARK: Bot editor

private struct BotEditorView: View {
    @ObservedObject var hub: PreferencesHub
    let bot: Bot?
    let onClose: () -> Void

    @State private var name: String
    @State private var color: Color
    @State private var agentKind: AgentKind
    @State private var blob: BlobKind?
    @State private var prompt: String
    @State private var skill: String
    @State private var folder: String
    @State private var workspace: String
    @State private var error: String?

    init(hub: PreferencesHub, bot: Bot?, onClose: @escaping () -> Void) {
        self.hub = hub; self.bot = bot; self.onClose = onClose
        _name = State(initialValue: bot?.name ?? "")
        _color = State(initialValue: bot.flatMap { Color(hex: $0.colorHex) } ?? Color(hex: "#9E9BFF")!)
        _agentKind = State(initialValue: bot?.agentKind ?? .claudeCode)
        _blob = State(initialValue: BlobKind(storageName: bot?.blobKindName))
        _prompt = State(initialValue: bot?.startPrompt ?? "")
        _skill = State(initialValue: LaunchOptions.current.demoBotSkill ?? bot?.skill ?? "")
        _folder = State(initialValue: bot?.defaultFolder ?? "")
        _workspace = State(initialValue: bot?.defaultWorkspace ?? "")
    }

    private var promptTooLong: Bool { prompt.count > PreferenceText.maxStartPromptLength }
    private var nameTooLong: Bool { name.count > PreferenceText.maxNameLength }
    private var skillTooLong: Bool { skill.count > PreferenceText.maxSkillCommandLength }
    private var skillInvalid: Bool { !skill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && PreferenceText.validSkill(skill) == nil }
    private var folderInvalid: Bool { !folder.trimmingCharacters(in: .whitespaces).isEmpty && PreferenceText.folderPath(folder) == nil }
    private var workspaceInvalid: Bool { !workspace.isEmpty && PreferenceText.workspaceName(workspace) == nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !promptTooLong && !nameTooLong && !skillTooLong
            && !folderInvalid && !workspaceInvalid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(bot == nil ? "New bot" : "Edit bot").font(.headline)
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    field("Name") {
                        TextField("Bot name", text: $name).textFieldStyle(.roundedBorder)
                        if nameTooLong { limitNote("Name is limited to \(PreferenceText.maxNameLength) characters.") }
                    }
                    field("Agent type") {
                        Picker("Agent type", selection: $agentKind) {
                            ForEach(AgentKind.allCases, id: \.self) { Text($0.settingsTitle).tag($0) }
                        }.labelsHidden()
                        Text("Only Claude Code bots appear in New session.").font(.caption2).foregroundStyle(.secondary)
                    }
                    field("Color") {
                        HStack {
                            ColorPicker("Color", selection: $color, supportsOpacity: false).labelsHidden()
                            Text(color.hexString).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    field("Blob shape") {
                        Picker("Blob shape", selection: $blob) {
                            Text("Automatic").tag(BlobKind?.none)
                            Divider()
                            ForEach(BlobKind.allCases, id: \.self) { Text($0.settingsTitle).tag(BlobKind?.some($0)) }
                        }.labelsHidden()
                    }
                }
                VStack(spacing: 6) {
                    Text("Preview").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    BlobView(state: .working, kind: blob ?? BlobKind.forSession(bot?.id ?? name), size: 56, tint: color, seed: name)
                        .frame(width: 70, height: 70)
                    Text(name.isEmpty ? "Unnamed" : name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .frame(width: 130)
            }
            field("Start prompt") {
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(promptTooLong ? Color.red : Color.primary.opacity(0.2)))
                HStack {
                    Text("Sent as the first message of a session started with this bot.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(prompt.count) + " / " + String(PreferenceText.maxStartPromptLength)).font(.caption2.monospacedDigit())
                        .foregroundStyle(promptTooLong ? Color.red : Color.secondary)
                }
            }
            field("Skill (optional)") {
                TextField("Skill name, e.g. review-code", text: $skill).textFieldStyle(.roundedBorder)
                if skillTooLong { limitNote("Skill is limited to \(PreferenceText.maxSkillCommandLength) characters.") }
                else if skillInvalid { limitNote(PreferencesError.invalidSkill.settingsMessage) }
                else if let cmd = PreferenceText.validSkill(skill) {
                    Text("The first message starts with /\(cmd).").font(.caption2).foregroundStyle(.secondary)
                }
            }
            field("Default folder (optional)") {
                HStack {
                    TextField("/Users/you/project", text: $folder).textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        let open = NSOpenPanel()
                        open.canChooseDirectories = true; open.canChooseFiles = false; open.allowsMultipleSelection = false
                        open.canCreateDirectories = true; open.prompt = "Choose"
                        open.directoryURL = PreferenceText.folderPath(folder).map { URL(fileURLWithPath: $0) }
                        if open.runModal() == .OK, let url = open.url { folder = url.path }
                    }
                }
                if folderInvalid { limitNote("Use an absolute path without \"..\".") }
                else { Text("Preselected in the New session flow when the session runs as you.").font(.caption2).foregroundStyle(.secondary) }
            }
            field("Default \(AgentUser.name) workspace (optional)") {
                TextField("workspace-name", text: $workspace).textFieldStyle(.roundedBorder)
                if workspaceInvalid { limitNote("Letters, digits, dot, dash, underscore; max 64; no leading dot.") }
                else { Text("Preselected when the session runs as \(AgentUser.name).").font(.caption2).foregroundStyle(.secondary) }
            }
            }
            .padding(.trailing, 12)
            }
            .frame(height: 440)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func limitNote(_ s: String) -> some View { Text(s).font(.caption2).foregroundStyle(.red) }

    private func save() {
        let hex = color.hexString
        do {
            if var b = bot {
                b.name = name; b.colorHex = hex; b.agentKind = agentKind; b.blobKindName = blob?.storageName
                b.startPrompt = prompt; b.skill = skill.isEmpty ? nil : skill
                b.defaultFolder = folder; b.defaultWorkspace = workspace
                try hub.store.updateBot(b)
            } else {
                try hub.store.createBot(name: name, colorHex: hex, blobKindName: blob?.storageName, agentKind: agentKind,
                                        startPrompt: prompt, skill: skill.isEmpty ? nil : skill,
                                        defaultFolder: folder, defaultWorkspace: workspace)
            }
            onClose()
        } catch let e as PreferencesError {
            error = e.settingsMessage
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Setup

/// Read-only status list of the setup steps (same rows as the onboarding) plus a button to open the onboarding.
private struct SetupSettingsView: View {
    @State private var state: SetupState?
    @State private var loading = false

    private static let order: [SetupStep] = [.claudeCLI, .agentUser, .hostBinary, .cli, .claudeToken, .claudeHooks, .codexHooks, .autostart, .notifications]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Setup").font(.headline)
                Spacer()
                Button("Refresh") { Task { await load() } }.disabled(loading)
                Button("Open setup…") { SetupCoordinator.shared.show() }
            }
            if SetupCoordinator.shared.runner == nil {
                Text("Demo mode: no real setup state.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(Self.order.enumerated()), id: \.element) { i, step in
                        if i > 0 { Divider() }
                        row(step)
                    }
                }
            }
        }
        .padding(20)
        .task { await load() }
    }

    private func row(_ step: SetupStep) -> some View {
        let status = state?.status(of: step)
        let (icon, color, text): (String, Color, String) = {
            switch status {
            case .done?: return ("checkmark.circle.fill", .green, "Done")
            case .failed(let m)?: return ("exclamationmark.circle.fill", .red, m)
            case .notApplicable(let m)?: return ("minus.circle", .secondary, m)
            case .running?: return ("circle.dotted", .secondary, "Running")
            case .missing?: return ("circle", .orange, "Not set up")
            case nil: return ("circle.dotted", .secondary, loading ? "Checking…" : "Unknown")
            }
        }()
        return HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.onboardingTitle)
                Text(step.onboardingDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing).frame(maxWidth: 200, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    private func load() async {
        guard let runner = SetupCoordinator.shared.runner else { return }
        loading = true
        state = await runner.refresh()
        loading = false
    }
}
