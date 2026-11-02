import Foundation

/// Pure-logic installer for the Codex hook entries in `~/.codex/hooks.json` (same file shape as Claude's `hooks` key).
/// UNVERIFIED against a real Codex (not installed locally). Writing goes through `HookSetup.apply` (confirmation
/// callback, timestamped backup, atomic write, post-validation). Our entries contain `agentbar hook`.
/// Codex additionally requires the user to trust new/changed hooks via `/hooks` before they run.
public struct CodexHookSetup: Sendable {
    /// event -> (matcher, timeout seconds). SessionEnd/Interrupt allow max 3 s in Codex.
    static let entries: [(event: String, matcher: String?, timeout: Int)] = [
        ("PermissionRequest", "*", 600),
        ("PreToolUse", "*", 5),
        ("UserPromptSubmit", nil, 5),
        ("Stop", nil, 5),
        ("SessionStart", nil, 5),
        ("SessionEnd", nil, 2),
        ("Interrupt", nil, 2),
    ]

    public let hooksURL: URL
    public let agentbarPath: String
    private let base: HookSetup

    public static var defaultHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }

    public init(hooksURL: URL = CodexHookSetup.defaultHooksURL, agentbarPath: String,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.hooksURL = hooksURL; self.agentbarPath = agentbarPath
        self.base = HookSetup(settingsURL: hooksURL, agentbarPath: agentbarPath, now: now)
    }

    public func command() throws -> String {
        let c = try base.command()   // validates and escapes the path
        return c.replacingOccurrences(of: "--adapter claudeCode", with: "--adapter \(CodexAdapter.adapterId)")
    }

    public func planInstall() throws -> HookSetup.Plan { try plan(install: true) }
    public func planUninstall() throws -> HookSetup.Plan { try plan(install: false) }

    @discardableResult
    public func apply(_ plan: HookSetup.Plan, confirm: (HookSetup.Plan) -> Bool) throws -> HookSetup.Outcome {
        try base.apply(plan, confirm: confirm)
    }

    private func isOurs(_ handler: Any) -> Bool {
        ((handler as? [String: Any])?["command"] as? String)?.contains(HookSetup.marker) == true
    }

    private func plan(install: Bool) throws -> HookSetup.Plan {
        typealias E = HookSetup.SetupError
        var root: [String: Any] = [:]
        var origData: Data?
        if FileManager.default.fileExists(atPath: hooksURL.path) {
            let data = try Data(contentsOf: hooksURL)
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw E.invalidJSON("hooks.json is not a JSON object")
            }
            origData = data; root = obj
        }
        var settings = root
        var summary: [String] = []
        var hooks: [String: Any] = [:]
        if let h = settings["hooks"] {
            guard let hd = h as? [String: Any] else { throw E.unexpectedStructure("\"hooks\" is not an object") }
            hooks = hd
        }
        let cmd = install ? try command() : ""
        for (event, matcher, timeout) in Self.entries {
            var groups: [Any] = []
            if let g = hooks[event] {
                guard let ga = g as? [Any] else { throw E.unexpectedStructure("hooks.\(event) is not an array") }
                groups = ga
            }
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
                    if kept.isEmpty && !hs.isEmpty { continue }
                    group["hooks"] = kept; newGroups.append(group)
                }
                if removed > 0 {
                    summary.append("remove \(event): \(removed) AgentBar hook(s)")
                    hooks[event] = newGroups.isEmpty ? nil : newGroups
                }
            }
        }
        if install { settings["hooks"] = hooks }
        else if !summary.isEmpty { settings["hooks"] = hooks.isEmpty ? nil : hooks }

        let normalizedOrig = try HookSetup.serialize(root)
        let proposed = try HookSetup.serialize(settings)
        let noOp = summary.isEmpty
        let diff = noOp ? "" : HookSetup.unifiedDiff(old: String(decoding: normalizedOrig, as: UTF8.self),
                                                     new: String(decoding: proposed, as: UTF8.self))
        var preview = "File: \(hooksURL.path)\n(UNVERIFIED against a real Codex. Codex asks you to trust new hooks via /hooks.)\n"
        if origData == nil { preview += "(file does not exist yet and will be created)\n" }
        else if !noOp && origData != normalizedOrig { preview += "(note: the file will be re-formatted: 2-space indent, sorted keys; all content is kept)\n" }
        preview += noOp ? (install ? "\nAlready set up. No changes needed.\n" : "\nNo AgentBar hooks found. Nothing to remove.\n")
                        : "\n" + summary.map { "* \($0)" }.joined(separator: "\n") + "\n\n" + diff
        return HookSetup.Plan(original: origData, proposed: proposed, summary: summary, isNoOp: noOp, preview: preview)
    }
}
