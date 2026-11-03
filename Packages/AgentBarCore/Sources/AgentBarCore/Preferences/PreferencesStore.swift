import Foundation

/// Owner-side personalization store: one JSON file (version field), atomic 0600 writes, fault tolerant loading,
/// thread safe. Precedence for a session's color: session override > bot > agent-type default > theme palette >
/// legacy djb2 tint. Display names follow the same order and finally fall back to the project name.
public final class PreferencesStore: @unchecked Sendable {
    public static let currentVersion = 1
    public static let maxSessionOverrides = 1000
    public static let maxBots = 100
    public static let maxSessionIDLength = 200

    struct File: Codable {
        var version: Int
        var theme: ThemePalette
        var agentDefaults: [String: AgentAppearance]
        var sessions: [String: AgentAppearance]
        var sessionBots: [String: String]
        var bots: [Bot]
        /// nil = never customized (the defaults apply). Added after version 1 shipped: absent in older files, still readable.
        var mascot: MascotAppearance?
        static let empty = File(version: PreferencesStore.currentVersion, theme: .automatic, agentDefaults: [:],
                                sessions: [:], sessionBots: [:], bots: [])

        init(version: Int, theme: ThemePalette, agentDefaults: [String: AgentAppearance], sessions: [String: AgentAppearance],
             sessionBots: [String: String], bots: [Bot], mascot: MascotAppearance? = nil) {
            self.version = version; self.theme = theme; self.agentDefaults = agentDefaults
            self.sessions = sessions; self.sessionBots = sessionBots; self.bots = bots; self.mascot = mascot
        }

        // Lenient decoding: unknown theme or a broken single bot/entry must not discard everything else.
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: Keys.self)
            version = try c.decode(Int.self, forKey: .version)
            theme = (try? c.decode(ThemePalette.self, forKey: .theme)) ?? .automatic
            agentDefaults = (try? c.decode([String: AgentAppearance].self, forKey: .agentDefaults)) ?? [:]
            sessions = (try? c.decode([String: AgentAppearance].self, forKey: .sessions)) ?? [:]
            sessionBots = (try? c.decode([String: String].self, forKey: .sessionBots)) ?? [:]
            bots = ((try? c.decode([Lossy<Bot>].self, forKey: .bots)) ?? []).compactMap(\.value)
            mascot = try? c.decodeIfPresent(MascotAppearance.self, forKey: .mascot)
        }
        enum Keys: String, CodingKey { case version, theme, agentDefaults, sessions, sessionBots, bots, mascot }
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from d: Decoder) throws { value = try? T(from: d) }
    }

    public let fileURL: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var data: File = .empty
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private var blocked = false
    private var saveError: Error?

    /// `~/Library/Application Support/AgentBar/preferences.json` of the current (owner) user.
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("AgentBar", isDirectory: true).appendingPathComponent("preferences.json")
    }

    public init(fileURL: URL = PreferencesStore.defaultFileURL(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    // MARK: change notification

    /// Registers a callback fired (outside the lock, on the mutating thread) after every change. Hop to the main
    /// actor yourself in SwiftUI code.
    @discardableResult
    public func addChangeObserver(_ f: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = f; lock.unlock()
        return id
    }

    public func removeChangeObserver(_ id: UUID) {
        lock.lock(); observers[id] = nil; lock.unlock()
    }

    /// Last write error, nil if the last save worked.
    public var lastSaveError: Error? { lock.lock(); defer { lock.unlock() }; return saveError }

    /// True if an unreadable file could not be backed up; the store then keeps defaults in memory and never writes.
    public var isReadOnly: Bool { lock.lock(); defer { lock.unlock() }; return blocked }

    // MARK: reads

    public var theme: ThemePalette { lock.lock(); defer { lock.unlock() }; return data.theme }

    public func agentDefault(for kind: AgentKind) -> AgentAppearance {
        lock.lock(); defer { lock.unlock() }; return data.agentDefaults[kind.rawValue] ?? AgentAppearance()
    }

    public func sessionOverride(for sessionID: String) -> AgentAppearance {
        lock.lock(); defer { lock.unlock() }; return data.sessions[sessionID] ?? AgentAppearance()
    }

    /// The owner's mascot (defaults until customized).
    public func mascot() -> MascotAppearance {
        lock.lock(); defer { lock.unlock() }; return data.mascot ?? .standard
    }

    public func bots() -> [Bot] {
        lock.lock(); defer { lock.unlock() }
        return data.bots.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func bot(id: String) -> Bot? {
        lock.lock(); defer { lock.unlock() }; return data.bots.first { $0.id == id }
    }

    public func botID(forSession sessionID: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return data.sessionBots[sessionID]
    }

    /// Resolves name and color. `project` is the app-known project/folder name used as last name fallback.
    public func appearance(forSession sessionID: String, kind: AgentKind, project: String) -> ResolvedAppearance {
        lock.lock(); defer { lock.unlock() }
        let s = data.sessions[sessionID]
        let bot = data.sessionBots[sessionID].flatMap { id in data.bots.first { $0.id == id } }
        let def = data.agentDefaults[kind.rawValue]
        let name = s?.displayName ?? bot?.name ?? def?.displayName ?? PreferenceText.name(project) ?? ""
        let hex: String, src: AppearanceSource
        if let c = s?.colorHex { (hex, src) = (c, .session) }
        else if let c = bot?.colorHex { (hex, src) = (c, .bot) }
        else if let c = def?.colorHex { (hex, src) = (c, .agentDefault) }
        else if let c = data.theme.defaultColorHex(for: kind) { (hex, src) = (c, .theme) }
        else { (hex, src) = (ThemePalette.legacyTintHex(forSession: sessionID), .legacyTint) }
        return ResolvedAppearance(displayName: name, colorHex: hex, colorSource: src, blobKindName: bot?.blobKindName, botID: bot?.id)
    }

    // MARK: setters

    public func setTheme(_ theme: ThemePalette) {
        mutate { $0.theme = theme }
    }

    /// Sets the session's display name; nil (or an input that is empty after cleaning) clears it.
    public func setSessionName(_ sessionID: String, _ name: String?) throws {
        try editSession(sessionID) { $0.displayName = PreferenceText.name(name) }
    }

    /// Sets the session's color; nil clears it, an invalid hex throws and changes nothing.
    public func setSessionColor(_ sessionID: String, _ colorHex: String?) throws {
        let c = try Self.checkedColor(colorHex)
        try editSession(sessionID) { $0.colorHex = c }
    }

    public func clearSession(_ sessionID: String) {
        mutate { $0.sessions[sessionID] = nil; $0.sessionBots[sessionID] = nil }
    }

    public func setAgentDefaultName(_ kind: AgentKind, _ name: String?) {
        editDefault(kind) { $0.displayName = PreferenceText.name(name) }
    }

    public func setAgentDefaultColor(_ kind: AgentKind, _ colorHex: String?) throws {
        let c = try Self.checkedColor(colorHex)
        editDefault(kind) { $0.colorHex = c }
    }

    private func editSession(_ id: String, _ f: @escaping (inout AgentAppearance) -> Void) throws {
        guard Self.validSessionID(id) else { throw PreferencesError.invalidSessionID }
        try mutateChecked { d in
            if d.sessions[id] == nil, d.sessions.count >= Self.maxSessionOverrides { throw PreferencesError.limitReached }
            var a = d.sessions[id] ?? AgentAppearance()
            f(&a)
            d.sessions[id] = a.isEmpty ? nil : a
        }
    }

    private func editDefault(_ kind: AgentKind, _ f: @escaping (inout AgentAppearance) -> Void) {
        mutate { d in
            var a = d.agentDefaults[kind.rawValue] ?? AgentAppearance()
            f(&a)
            d.agentDefaults[kind.rawValue] = a.isEmpty ? nil : a
        }
    }

    /// Binds a session to a bot (nil unbinds). Throws `notFound` for an unknown bot id.
    public func setBot(_ botID: String?, forSession sessionID: String) throws {
        guard Self.validSessionID(sessionID) else { throw PreferencesError.invalidSessionID }
        try mutateChecked { d in
            if let botID {
                guard d.bots.contains(where: { $0.id == botID }) else { throw PreferencesError.notFound }
                if d.sessionBots[sessionID] == nil, d.sessionBots.count >= Self.maxSessionOverrides { throw PreferencesError.limitReached }
            }
            d.sessionBots[sessionID] = botID
        }
    }

    // MARK: mascot

    /// Stores the mascot. Same rules as bots: the name must be non-empty after cleaning (`invalidName`), the color a valid
    /// hex (`invalidColor`), an unknown body name falls back to the default shape. Throws change nothing.
    @discardableResult
    public func setMascot(_ mascot: MascotAppearance) throws -> MascotAppearance {
        guard let n = PreferenceText.name(mascot.name) else { throw PreferencesError.invalidName }
        guard let c = HexColor.normalize(mascot.colorHex) else { throw PreferencesError.invalidColor }
        var m = mascot
        m.name = n; m.colorHex = c
        m.bodyKindName = PreferenceText.blobKindName(mascot.bodyKindName) ?? MascotAppearance.defaultBodyKindName
        try mutateChecked { $0.mascot = m }
        return m
    }

    /// Back to the defaults (the file stores nothing for the mascot afterwards).
    public func resetMascot() {
        mutate { $0.mascot = nil }
    }

    // MARK: bots

    /// Creates a bot with a fresh id. Name must be non-empty after cleaning; color must be valid.
    @discardableResult
    public func createBot(name: String, colorHex: String, blobKindName: String? = nil, agentKind: AgentKind,
                          startPrompt: String, skill: String? = nil, defaultFolder: String? = nil,
                          defaultWorkspace: String? = nil) throws -> Bot {
        guard let n = PreferenceText.name(name) else { throw PreferencesError.invalidName }
        guard let c = HexColor.normalize(colorHex) else { throw PreferencesError.invalidColor }
        let folder = try Self.checkedFolder(defaultFolder), workspace = try Self.checkedWorkspace(defaultWorkspace)
        let bot = Bot(id: UUID().uuidString, name: n, colorHex: c, blobKindName: PreferenceText.blobKindName(blobKindName),
                      agentKind: agentKind, startPrompt: PreferenceText.startPrompt(startPrompt) ?? "",
                      skill: PreferenceText.skill(skill), defaultFolder: folder, defaultWorkspace: workspace, createdAt: Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)))  // whole seconds: iso8601 roundtrip
        try mutateChecked { d in
            guard d.bots.count < Self.maxBots else { throw PreferencesError.limitReached }
            d.bots.append(bot)
        }
        return bot
    }

    /// Replaces the mutable fields of an existing bot (id and createdAt are kept), with the same validation as create.
    @discardableResult
    public func updateBot(_ bot: Bot) throws -> Bot {
        guard let n = PreferenceText.name(bot.name) else { throw PreferencesError.invalidName }
        guard let c = HexColor.normalize(bot.colorHex) else { throw PreferencesError.invalidColor }
        let folder = try Self.checkedFolder(bot.defaultFolder), workspace = try Self.checkedWorkspace(bot.defaultWorkspace)
        var result: Bot?
        try mutateChecked { d in
            guard let i = d.bots.firstIndex(where: { $0.id == bot.id }) else { throw PreferencesError.notFound }
            var b = d.bots[i]
            b.name = n; b.colorHex = c; b.blobKindName = PreferenceText.blobKindName(bot.blobKindName)
            b.agentKind = bot.agentKind; b.startPrompt = PreferenceText.startPrompt(bot.startPrompt) ?? ""
            b.skill = PreferenceText.skill(bot.skill)
            b.defaultFolder = folder; b.defaultWorkspace = workspace
            d.bots[i] = b; result = b
        }
        return result!
    }

    /// Removes a bot and the session bindings that point to it. Returns false if the id is unknown.
    @discardableResult
    public func deleteBot(id: String) -> Bool {
        var found = false
        mutate { d in
            found = d.bots.contains { $0.id == id }
            guard found else { return }
            d.bots.removeAll { $0.id == id }
            d.sessionBots = d.sessionBots.filter { $0.value != id }
        }
        return found
    }

    // MARK: internals

    private static func validSessionID(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= maxSessionIDLength }

    /// nil/blank => nil; a value that is not a valid absolute folder path throws and changes nothing.
    private static func checkedFolder(_ f: String?) throws -> String? {
        guard let f, !f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let p = PreferenceText.folderPath(f) else { throw PreferencesError.invalidFolder }
        return p
    }

    private static func checkedWorkspace(_ w: String?) throws -> String? {
        guard let w, !w.isEmpty else { return nil }
        guard let n = PreferenceText.workspaceName(w) else { throw PreferencesError.invalidWorkspace }
        return n
    }

    private static func checkedColor(_ c: String?) throws -> String? {
        guard let c else { return nil }
        guard let n = HexColor.normalize(c) else { throw PreferencesError.invalidColor }
        return n
    }

    private func mutate(_ f: (inout File) -> Void) {
        try? mutateChecked { f(&$0) }
    }

    /// Applies `f` to a copy; on success commits, persists and notifies. Errors leave the state untouched.
    private func mutateChecked(_ f: (inout File) throws -> Void) throws {
        lock.lock()
        var copy = data
        do { try f(&copy) } catch { lock.unlock(); throw error }
        data = copy
        persistLocked()
        let cbs = Array(observers.values)
        lock.unlock()
        cbs.forEach { $0() }
    }

    // MARK: persistence

    private func load() {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            let raw = try Data(contentsOf: fileURL)
            var f = try Self.decoder.decode(File.self, from: raw)
            guard f.version >= 1, f.version <= Self.currentVersion else { throw CocoaError(.fileReadCorruptFile) }
            Self.sanitize(&f)
            data = f
        } catch {
            // Keep the unreadable file as .bak before anything can overwrite it; if that fails, never write.
            let bak = fileURL.appendingPathExtension("bak")
            do {
                try? fm.removeItem(at: bak)
                try fm.copyItem(at: fileURL, to: bak)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bak.path)
            } catch { blocked = true }
            data = .empty
        }
    }

    /// Re-validates everything loaded from disk (the file is editable by hand).
    private static func sanitize(_ f: inout File) {
        f.version = currentVersion
        f.agentDefaults = f.agentDefaults.filter { AgentKind(rawValue: $0.key) != nil }
            .compactMapValues { let a = $0.sanitized(); return a.isEmpty ? nil : a }
        f.sessions = f.sessions.filter { validSessionID($0.key) }
            .compactMapValues { let a = $0.sanitized(); return a.isEmpty ? nil : a }
        var seen = Set<String>()
        f.bots = f.bots.compactMap { b in
            guard let n = PreferenceText.name(b.name), let c = HexColor.normalize(b.colorHex), seen.insert(b.id).inserted else { return nil }
            var x = b
            x.name = n; x.colorHex = c; x.blobKindName = PreferenceText.blobKindName(b.blobKindName)
            x.startPrompt = PreferenceText.startPrompt(b.startPrompt) ?? ""; x.skill = PreferenceText.skill(b.skill)
            x.defaultFolder = PreferenceText.folderPath(b.defaultFolder); x.defaultWorkspace = PreferenceText.workspaceName(b.defaultWorkspace)
            return x
        }.prefix(maxBots).map { $0 }
        let ids = Set(f.bots.map(\.id))
        f.sessionBots = f.sessionBots.filter { validSessionID($0.key) && ids.contains($0.value) }
        f.mascot = f.mascot?.sanitized()
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }

    private func persistLocked() {
        guard !blocked else { saveError = CocoaError(.fileWriteNoPermission); return }
        do {
            try Self.writeAtomically(try Self.encoder.encode(data), to: fileURL)
            saveError = nil
        } catch { saveError = error }
    }

    /// temp file (O_EXCL, 0600) in the target directory, fsync, rename over the target.
    static func writeAtomically(_ bytes: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = false
        defer { close(fd); if !ok { unlink(tmp) } }
        try bytes.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                off += n
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0, rename(tmp, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        ok = true
    }
}
