import Foundation

/// Pure-logic installer for the Claude Code hook entries in a `settings.json`.
/// Nothing is written without an explicit confirmation callback; a timestamped backup precedes every write.
/// Our entries are recognizable by a handler command containing `agentbar hook`.
public struct HookSetup: Sendable {
    public enum SetupError: Error, Equatable, CustomStringConvertible {
        case invalidJSON(String)          // existing settings are not a valid JSON object
        case unexpectedStructure(String)  // e.g. "hooks" is not an object
        case invalidBinary(String)
        case changedOnDisk
        case validationFailed(String)
        public var description: String {
            switch self {
            case .invalidJSON(let s): return "settings.json is not valid JSON: \(s)"
            case .unexpectedStructure(let s): return "unexpected settings structure: \(s)"
            case .invalidBinary(let s): return "invalid agentbar path: \(s)"
            case .changedOnDisk: return "settings.json changed after the preview; nothing was written"
            case .validationFailed(let s): return "validation failed: \(s)"
            }
        }
    }

    public enum Outcome: Equatable { case applied(backup: URL?), unchanged, cancelled }

    public struct Plan: Sendable {
        public let original: Data?        // nil = file does not exist
        public let proposed: Data
        public let summary: [String]      // human-readable list of changes
        public let isNoOp: Bool
        /// Summary + unified-style diff, ready to show in a dialog.
        public let preview: String
    }

    /// event -> (matcher, timeout seconds)
    static let entries: [(event: String, matcher: String?, timeout: Int)] = [
        ("PermissionRequest", "*", 600),   // blocking: waits for the user (app side times out earlier)
        ("PreToolUse", "*", 5),            // activity display only, never decides
        ("Notification", nil, 5),
        ("Stop", nil, 5),
        ("UserPromptSubmit", nil, 5),
        ("SessionStart", nil, 5),
        ("SessionEnd", nil, 5),
    ]
    static let marker = "agentbar hook"

    public let settingsURL: URL
    public let agentbarPath: String
    private let now: @Sendable () -> Date

    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    public init(settingsURL: URL = HookSetup.defaultSettingsURL, agentbarPath: String,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.settingsURL = settingsURL; self.agentbarPath = agentbarPath; self.now = now
    }

    /// Where the CLI is expected: next to the app executable, in Resources, or a user override.
    public static func locateCLI(bundle: Bundle = .main, override: String? = nil) -> String? {
        var c: [String] = []
        if let o = override, !o.isEmpty { c.append(o) }
        if let exe = bundle.executableURL?.deletingLastPathComponent() { c.append(exe.appendingPathComponent("agentbar").path) }
        if let res = bundle.resourceURL { c.append(res.appendingPathComponent("agentbar").path) }
        return c.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func command() throws -> String {
        guard agentbarPath.hasPrefix("/"), (agentbarPath as NSString).lastPathComponent == "agentbar",
              !agentbarPath.contains("\n"), !agentbarPath.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw SetupError.invalidBinary(agentbarPath)
        }
        // Backslash-escape shell metacharacters so the path stays one word and "agentbar hook" stays literal.
        var esc = ""
        for ch in agentbarPath {
            if !(ch.isLetter || ch.isNumber || "/._-+@".contains(ch)) { esc.append("\\") }
            esc.append(ch)
        }
        return "\(esc) hook --adapter claudeCode"
    }

    // MARK: planning

    public func planInstall() throws -> Plan { try plan(install: true) }
    public func planUninstall() throws -> Plan { try plan(install: false) }

    private func readOriginal() throws -> (Data?, [String: Any]) {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return (nil, [:]) }
        let data = try Data(contentsOf: settingsURL)
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any] else { throw SetupError.invalidJSON("top level is not an object") }
            return (data, dict)
        } catch let e as SetupError { throw e } catch { throw SetupError.invalidJSON(error.localizedDescription) }
    }

    static func serialize(_ d: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private func isOurs(_ handler: Any) -> Bool {
        ((handler as? [String: Any])?["command"] as? String)?.contains(Self.marker) == true
    }

    private func plan(install: Bool) throws -> Plan {
        let (origData, root) = try readOriginal()
        var settings = root
        var summary: [String] = []
        var hooks: [String: Any]
        if let h = settings["hooks"] {
            guard let hd = h as? [String: Any] else { throw SetupError.unexpectedStructure("\"hooks\" is not an object") }
            hooks = hd
        } else { hooks = [:] }
        let cmd = install ? try command() : ""

        for (event, matcher, timeout) in Self.entries {
            var groups: [Any]
            if let g = hooks[event] {
                guard let ga = g as? [Any] else { throw SetupError.unexpectedStructure("hooks.\(event) is not an array") }
                groups = ga
            } else { groups = [] }

            if install {
                var found = false
                for gi in groups.indices {
                    guard var group = groups[gi] as? [String: Any], var hs = group["hooks"] as? [Any] else { continue }
                    var touched = false
                    for hi in hs.indices where isOurs(hs[hi]) {
                        found = true
                        var h = hs[hi] as! [String: Any]
                        if (h["command"] as? String) != cmd {
                            h["command"] = cmd; hs[hi] = h; touched = true
                            summary.append("update \(event): command -> \(cmd)")
                        }
                    }
                    if touched { group["hooks"] = hs; groups[gi] = group }
                }
                if !found {
                    var g: [String: Any] = ["hooks": [["type": "command", "command": cmd, "timeout": timeout] as [String: Any]]]
                    if let m = matcher { g["matcher"] = m }
                    groups.append(g)
                    summary.append("add \(event): \(cmd) (timeout \(timeout)s)")
                }
                hooks[event] = groups
            } else {
                var newGroups: [Any] = []
                var removed = 0
                for g in groups {
                    guard var group = g as? [String: Any], let hs = group["hooks"] as? [Any] else { newGroups.append(g); continue }
                    let kept = hs.filter { !isOurs($0) }
                    removed += hs.count - kept.count
                    if kept.isEmpty && !hs.isEmpty { continue }   // group only contained our entries
                    group["hooks"] = kept; newGroups.append(group)
                }
                if removed > 0 {
                    summary.append("remove \(event): \(removed) AgentBar hook(s)")
                    if newGroups.isEmpty { hooks[event] = nil } else { hooks[event] = newGroups }
                }
            }
        }
        if install { settings["hooks"] = hooks }
        else if !summary.isEmpty { if hooks.isEmpty { settings["hooks"] = nil } else { settings["hooks"] = hooks } }

        let normalizedOrig = try Self.serialize(root)
        let proposed = try Self.serialize(settings)
        let noOp = summary.isEmpty
        let diff = noOp ? "" : Self.unifiedDiff(old: String(decoding: normalizedOrig, as: UTF8.self),
                                                new: String(decoding: proposed, as: UTF8.self))
        var preview = "File: \(settingsURL.path)\n"
        if origData == nil { preview += "(file does not exist yet and will be created)\n" }
        else if !noOp && origData != normalizedOrig { preview += "(note: the file will be re-formatted: 2-space indent, sorted keys; all content is kept)\n" }
        preview += noOp ? (install ? "\nAlready set up. No changes needed.\n" : "\nNo AgentBar hooks found. Nothing to remove.\n")
                        : "\n" + summary.map { "* \($0)" }.joined(separator: "\n") + "\n\n" + diff
        return Plan(original: origData, proposed: proposed, summary: summary, isNoOp: noOp, preview: preview)
    }

    // MARK: applying

    /// Writes only if `confirm` returns true. Backup first, atomic write, validation before and after.
    @discardableResult
    public func apply(_ plan: Plan, confirm: (Plan) -> Bool) throws -> Outcome {
        if plan.isNoOp { return .unchanged }
        guard confirm(plan) else { return .cancelled }
        // Validate proposal.
        guard let o = try? JSONSerialization.jsonObject(with: plan.proposed), o is [String: Any] else {
            throw SetupError.validationFailed("proposed settings are not a JSON object")
        }
        let fm = FileManager.default
        let target = settingsURL.resolvingSymlinksInPath()
        // The file must still be what the user saw.
        let current: Data? = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        guard current == plan.original else { throw SetupError.changedOnDisk }

        var backup: URL?
        var perms: NSNumber?
        if current != nil {
            let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = fmt.string(from: now())
            var b = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".agentbar-backup-" + stamp)
            var n = 1
            while fm.fileExists(atPath: b.path) { n += 1; b = b.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".agentbar-backup-\(stamp)-\(n)") }
            try current!.write(to: b, options: .atomic)
            backup = b
            perms = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
            if let p = perms { try? fm.setAttributes([.posixPermissions: p], ofItemAtPath: b.path) }
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try plan.proposed.write(to: target, options: .atomic)
        if let p = perms { try? fm.setAttributes([.posixPermissions: p], ofItemAtPath: target.path) }
        // Post-validation; restore on failure.
        let after = try? Data(contentsOf: target)
        if after != plan.proposed || (after.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) == nil {
            if let c = current { try? c.write(to: target, options: .atomic) } else { try? fm.removeItem(at: target) }
            throw SetupError.validationFailed("written file did not verify; original restored")
        }
        return .applied(backup: backup)
    }

    // MARK: diff

    /// Minimal LCS line diff with 2 lines of context.
    static func unifiedDiff(old: String, new: String) -> String {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [(Character, String)] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { ops.append((" ", a[i])); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { ops.append(("-", a[i])); i += 1 }
            else { ops.append(("+", b[j])); j += 1 }
        }
        while i < a.count { ops.append(("-", a[i])); i += 1 }
        while j < b.count { ops.append(("+", b[j])); j += 1 }
        var show = [Bool](repeating: false, count: ops.count)
        for (k, op) in ops.enumerated() where op.0 != " " {
            for d in -2...2 where k + d >= 0 && k + d < ops.count { show[k + d] = true }
        }
        var out: [String] = []
        var gap = false
        for (k, op) in ops.enumerated() {
            if show[k] { if gap { out.append("  ..."); gap = false }; out.append("\(op.0) \(op.1)") }
            else { gap = true }
        }
        return out.joined(separator: "\n")
    }
}
