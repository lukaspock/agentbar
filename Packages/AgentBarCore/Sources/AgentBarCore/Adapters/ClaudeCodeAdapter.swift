import Foundation

/// Adapter for Claude Code hooks (stdin JSON in, `hookSpecificOutput` JSON out).
///
/// Design notes
/// - `encode(response:for:)` only receives the response and the `AgentRequest`. The hook event name and the
///   `permission_suggestions` (needed for "always") are not part of those, so they are kept in a small
///   thread-safe side table keyed by `requestId` (set in `translate`, consumed in `encode`). The request's option
///   ids stay the contract ids ("allow"/"deny"/"always"). The table is bounded (oldest entries are evicted), so
///   requests that are cancelled by a client disconnect (never encoded) cannot leak memory.
/// - Received text is data: it is only ever sanitized and displayed, never executed or interpreted.
/// - Safe default: timeout, cancel, unknown request, unknown option => empty output (Claude shows its own dialog).
public final class ClaudeCodeAdapter: AgentAdapter, @unchecked Sendable {
    public var kind: AgentKind { .claudeCode }

    public static let maxPayloadBytes = 256 * 1024
    public static let approvalTimeoutSeconds = 120
    /// Max characters of a logged user prompt / assistant reply (chat bubbles). Far below `AgentBarLimits.maxTextLength`.
    static let maxPromptLog = 300
    static let maxReplyLog = 400
    static let maxPendingTable = 256

    public enum AdapterError: Error, Equatable { case malformed(String) }

    private struct Pending { var suggestion: Data? }   // the chosen suggestion entry as JSON, if any
    private let lock = NSLock()
    private var table: [String: Pending] = [:]
    private var order: [String] = []

    public init() {}

    // MARK: translate

    public func translate(payload: Data) throws -> [CoreEvent] {
        guard payload.count <= Self.maxPayloadBytes else { throw AdapterError.malformed("payload too large") }
        guard let root = try? JSONSerialization.jsonObject(with: payload),
              let obj = root as? [String: Any] else { throw AdapterError.malformed("not a JSON object") }
        guard let event = obj["hook_event_name"] as? String, !event.isEmpty else {
            throw AdapterError.malformed("missing hook_event_name")
        }
        let known: Set<String> = ["PermissionRequest", "PreToolUse", "Notification", "Stop", "SubagentStop",
                                  "UserPromptSubmit", "SessionStart", "SessionEnd"]
        guard known.contains(event) else { return [] }
        guard let sid = obj["session_id"] as? String, !sid.isEmpty, sid.count <= AgentBarLimits.maxIdLength else {
            throw AdapterError.malformed("missing session_id")
        }
        let name = Self.sessionName(cwd: obj["cwd"] as? String)

        func update(_ state: SessionState?, action: String? = nil) -> CoreEvent {
            .sessionUpdate(id: sid, name: name, kind: .claudeCode, state: state, action: action, supportsStop: nil)
        }

        switch event {
        case "SessionStart":
            return [update(.idle)]
        case "SessionEnd":
            return [.sessionEnd(id: sid)]
        case "UserPromptSubmit":
            // The user's prompt becomes a chat bubble ("You: ..."); no prompt field => nothing is logged.
            var events = [update(.working, action: "Thinking")]
            if let prompt = Self.clean(obj["prompt"] as? String, max: Self.maxPromptLog) {
                events.append(.log(sessionId: sid, entry: HistoryEntry(kind: .answer, text: "You: " + prompt)))
            }
            return events
        case "PreToolUse":
            let tool = Self.clean(obj["tool_name"] as? String, max: 60) ?? "tool"
            let summary = Self.summarize(tool: tool, input: obj["tool_input"])
            return [update(.working, action: summary.isEmpty ? tool : "\(tool): \(summary)")]
        case "Notification":
            let type = obj["notification_type"] as? String ?? ""
            let msg = Self.clean(obj["message"] as? String, max: 200) ?? "Claude needs your attention"
            let entry = CoreEvent.log(sessionId: sid, entry: HistoryEntry(kind: .status, text: msg))
            if ["permission_prompt", "idle_prompt", "agent_needs_input"].contains(type) || type.hasPrefix("elicitation") {
                return [update(.needsInput, action: msg), entry]
            }
            return [entry]
        case "Stop":
            // With a real assistant message the entry carries the "Claude: " agent prefix (shown as an agent bubble,
            // same convention as chat sessions); the "Finished" fallback stays a plain note.
            let last = Self.clean(obj["last_assistant_message"] as? String, max: Self.maxReplyLog).map { "Claude: " + $0 } ?? "Finished"
            return [update(.done), .log(sessionId: sid, entry: HistoryEntry(kind: .status, text: last))]
        case "SubagentStop":
            let last = Self.clean(obj["last_assistant_message"] as? String, max: 200) ?? "Subagent finished"
            return [.log(sessionId: sid, entry: HistoryEntry(kind: .status, text: "Subagent: \(last)"))]
        default: // PermissionRequest
            return permissionAsk(obj, sid: sid, name: name) { update($0, action: $1) }
        }
    }

    /// Max characters of an approval text. Stays below `AgentBarLimits.maxTextLength` so the store never cuts it.
    public static let maxApprovalText = AgentBarLimits.maxTextLength - 100
    public static let truncationMarker = "… [truncated, check in terminal]"

    private func permissionAsk(_ obj: [String: Any], sid: String, name: String, update: (SessionState?, String?) -> CoreEvent) -> [CoreEvent] {
        let rendered = Self.renderApproval(tool: obj["tool_name"] as? String, cwd: obj["cwd"] as? String,
                                           project: name, input: obj["tool_input"])
        guard let text = rendered.text else {
            // The input cannot be shown in full (too long / nothing renderable): never offer one-click Allow.
            // Empty hook output => Claude Code shows its own dialog; the bar only flags that attention is needed.
            let tool = Self.clean(obj["tool_name"] as? String, max: 60) ?? "tool"
            let msg = "\(tool): \(rendered.reason) \(Self.truncationMarker)"
            return [.sessionUpdate(id: sid, name: name, kind: .claudeCode, state: .needsInput, action: msg, supportsStop: nil),
                    .log(sessionId: sid, entry: HistoryEntry(kind: .status, text: msg))]
        }
        let suggestions = (obj["permission_suggestions"] as? [Any]) ?? []
        var chosen: Data?
        if !suggestions.isEmpty {
            let local = suggestions.first { ($0 as? [String: Any])?["destination"] as? String == "localSettings" }
            let pick = local ?? suggestions[0]
            if JSONSerialization.isValidJSONObject(pick) { chosen = try? JSONSerialization.data(withJSONObject: pick, options: [.sortedKeys]) }
        }
        var options = [RequestOption(id: "allow", label: "Allow", style: .primary),
                       RequestOption(id: "deny", label: "Deny", style: .destructive)]
        if chosen != nil { options.append(RequestOption(id: "always", label: "Always allow")) }
        let rid = UUID().uuidString
        remember(rid, Pending(suggestion: chosen))
        let req = AgentRequest(requestId: rid, type: .approval, text: text, options: options,
                               timeoutSeconds: Self.approvalTimeoutSeconds, defaultOptionId: nil)
        // name-only update first, so the card shows the project name instead of the raw session id
        return [update(nil, nil), .ask(sessionId: sid, request: req)]
    }

    /// Plain-text approval body: header line (tool, project), `cwd:` line, then one `key: value` entry per top-level
    /// key of `tool_input` (sorted). Continuation lines of a value are indented so a value can not forge a key line.
    /// Returns `text == nil` when it does not fit `maxApprovalText` or nothing can be rendered.
    static func renderApproval(tool: String?, cwd: String?, project: String, input: Any?)
        -> (text: String?, reason: String) {
        let limit = maxApprovalText
        let unreadable = "unreadable characters"
        if hasCollapsedCluster(tool ?? "") || hasCollapsedCluster(project) || hasCollapsedCluster(cwd ?? "") { return (nil, unreadable) }
        let toolRaw = singleLine(tool ?? "")
        guard !toolRaw.isEmpty else { return (nil, "unknown tool") }
        guard toolRaw.count <= 60 else { return (nil, "tool name too long") }
        guard let dict = input as? [String: Any], !dict.isEmpty else { return (nil, "no displayable parameters") }
        var lines = ["Allow \(toolRaw)?"]
        if let cwd, !singleLine(cwd).isEmpty { lines.append("cwd: \(singleLine(cwd))") }
        // Counted in Characters (what the store caps) AND in unicode scalars (a single grapheme can carry thousands).
        func size(_ str: String) -> Int { max(str.count, str.unicodeScalars.count) }
        var total = size(lines.joined(separator: "\n"))
        for key in dict.keys.sorted() {
            let rawValue = valueString(dict[key])
            if hasCollapsedCluster(key) || hasCollapsedCluster(rawValue) { return (nil, unreadable) }
            let k = singleLine(key)
            guard !k.isEmpty, k.count <= 60 else { return (nil, "parameter name not displayable") }
            var v = multiLine(rawValue)
            if v.isEmpty { v = "(empty)" }
            let entry = "\(k): " + v.replacingOccurrences(of: "\n", with: "\n  ")
            total += size(entry) + 1
            if total > limit { return (nil, "input too long") }
            lines.append(entry)
        }
        return (lines.joined(separator: "\n"), "")
    }

    private static func valueString(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case nil, is NSNull: return "null"
        case let x?:
            if JSONSerialization.isValidJSONObject(x) || x is NSNumber,
               let d = try? JSONSerialization.data(withJSONObject: x, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
                return String(decoding: d, as: UTF8.self)
            }
            return String(describing: x)
        }
    }

    /// Keeps newlines (max two in a row), turns other control/format characters (ESC, NUL, bidi overrides, ...)
    /// into a visible U+FFFD, tabs into spaces. Never caps: callers decide what to do with long text.
    static func multiLine(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var newlines = 0
        var prevCR = false
        for (u, keep) in units(s) {
            let cat = u.properties.generalCategory
            defer { prevCR = (u == "\r") }
            if keep { newlines = 0; out.append(u); continue }
            if u == "\n" || u == "\r" || cat == .lineSeparator || cat == .paragraphSeparator || u.value == 0x85 {
                if u == "\n", prevCR { continue }
                newlines += 1
                if newlines <= 2 { out.append("\n") }
                continue
            }
            newlines = 0
            if u == "\t" { out.append(" "); continue }
            if isHidden(u, cat) { out.append("\u{FFFD}"); continue }
            if cat == .spaceSeparator, u != " " { out.append(" "); continue }
            out.append(u)
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Max scalars per grapheme cluster (base + marks). More => the whole cluster becomes one U+FFFD (Zalgo overlay).
    static let maxClusterScalars = 3
    static let maxEmojiClusterScalars = 12

    /// Splits `s` into scalars; `keep == true` marks scalars of a legitimate emoji sequence (ZWJ, VS16, skin tones)
    /// that must bypass the hidden-character filter. Clusters with too many marks, an enclosing mark, or starting with
    /// a mark are replaced by a single (non-kept) U+FFFD.
    static func units(_ s: String) -> [(Unicode.Scalar, Bool)] {
        var res: [(Unicode.Scalar, Bool)] = []
        res.reserveCapacity(s.unicodeScalars.count)
        for ch in s {
            let sc = Array(ch.unicodeScalars)
            if sc.count == 1 || ch == "\r\n" { res.append(contentsOf: sc.map { ($0, false) }); continue }
            if isEmojiSequence(sc) { res.append(contentsOf: sc.map { ($0, true) }); continue }
            if collapses(sc) {
                res.append(("\u{FFFD}", false))
            } else {
                res.append(contentsOf: sc.map { ($0, false) })
            }
        }
        return res
    }

    /// True for a (non-emoji) cluster that `units` replaces by U+FFFD: the base character would vanish from the display.
    private static func collapses(_ sc: [Unicode.Scalar]) -> Bool {
        let first = sc[0].properties.generalCategory
        let leadingMark = first == .nonspacingMark || first == .spacingMark || first == .enclosingMark
        return leadingMark || sc.count > maxClusterScalars || sc.contains { $0.properties.generalCategory == .enclosingMark }
    }

    /// True if sanitizing `s` would collapse any cluster. Approvals must fail closed on this (display != real input).
    static func hasCollapsedCluster(_ s: String) -> Bool {
        for ch in s {
            let sc = Array(ch.unicodeScalars)
            if sc.count == 1 || ch == "\r\n" || isEmojiSequence(sc) { continue }
            if collapses(sc) { return true }
        }
        return false
    }

    private static func isEmojiSequence(_ sc: [Unicode.Scalar]) -> Bool {
        guard sc.count > 1, sc.count <= maxEmojiClusterScalars, sc[0].value > 0x7F, sc[0].properties.isEmoji else { return false }
        return sc.allSatisfy { u in
            if u.properties.generalCategory == .enclosingMark { return false }
            return u.value == 0x200D || u.value == 0xFE0F || (0x1F3FB...0x1F3FF).contains(u.value)
                || (u.value > 0x7F && u.properties.isEmoji)
        }
    }

    /// Invisible or deceptive scalars: controls, format (zero-width, bidi, tags), private use, unassigned, surrogates,
    /// variation selectors, combining grapheme joiner and blank-looking letters (Hangul fillers, braille blank).
    static func isHidden(_ u: Unicode.Scalar, _ cat: Unicode.GeneralCategory) -> Bool {
        switch cat {
        case .control, .format, .privateUse, .unassigned, .surrogate: return true
        default: break
        }
        switch u.value {
        case 0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0, 0xFE00...0xFE0F, 0xE0100...0xE01EF: return true
        default: return false
        }
    }

    static func singleLine(_ s: String) -> String {
        multiLine(s).replacingOccurrences(of: "\n", with: " ")
    }

    private func remember(_ id: String, _ p: Pending) {
        lock.lock(); defer { lock.unlock() }
        table[id] = p; order.append(id)
        while order.count > Self.maxPendingTable { table[order.removeFirst()] = nil }
    }

    private func take(_ id: String) -> Pending? {
        lock.lock(); defer { lock.unlock() }
        order.removeAll { $0 == id }
        return table.removeValue(forKey: id)
    }

    // MARK: encode

    public func encode(response: AgentResponse, for request: AgentRequest) -> Data {
        guard let pending = take(request.requestId) else { return Data() }
        guard response.reason == .answered, let opt = response.optionId else { return Data() }
        var decision: [String: Any]
        switch opt {
        case "allow":
            decision = ["behavior": "allow"]
        case "always":
            decision = ["behavior": "allow"]
            if let s = pending.suggestion, let entry = try? JSONSerialization.jsonObject(with: s) {
                decision["updatedPermissions"] = [entry]
            }
        case "deny":
            let msg = Self.clean(response.text, max: 200) ?? "Denied via AgentBar"
            decision = ["behavior": "deny", "message": msg]
        default:
            return Data()
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    }

    // MARK: sanitizing helpers

    static func sessionName(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        let base = (cwd as NSString).lastPathComponent
        return clean(base, max: AgentBarLimits.maxNameLength) ?? "Claude Code"
    }

    /// Replaces control characters with spaces, collapses whitespace, trims and caps. nil when empty.
    static func clean(_ s: String?, max: Int) -> String? {
        guard let s else { return nil }
        var out = ""
        var lastSpace = true
        for (u, keep) in units(s) {
            if keep { out.unicodeScalars.append(u); lastSpace = false; if out.count > max + 1 { break }; continue }
            let isCtl = isHidden(u, u.properties.generalCategory)
                || u.properties.generalCategory == .lineSeparator || u.properties.generalCategory == .paragraphSeparator
            if isCtl || u.properties.isWhitespace {
                if !lastSpace { out.unicodeScalars.append(" "); lastSpace = true }
            } else {
                out.unicodeScalars.append(u); lastSpace = false
            }
            if out.count > max + 1 { break }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        if out.isEmpty { return nil }
        return out.count > max ? String(out.prefix(max - 1)) + "…" : out
    }

    /// Short one-line description of tool input. Never dumps raw input.
    static func summarize(tool: String, input: Any?) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        for key in ["command", "file_path", "path", "url", "pattern", "query", "notebook_path", "description"] {
            if let v = dict[key] as? String, let c = clean(v, max: 200) { return c }
        }
        // Fallback: key names only (no values), capped.
        let keys = dict.keys.sorted().prefix(6).joined(separator: ", ")
        return clean(keys.isEmpty ? nil : "(\(keys))", max: 80) ?? ""
    }
}
