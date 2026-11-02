import Foundation

/// Wire format of `claude -p --input-format stream-json --output-format stream-json` (newline-delimited JSON).
///
/// UNVERIFIED against a real run (the local `claude` login was expired when this was written). Sources: public docs
/// (CLI reference, Agent SDK "Handle approvals and user input"/"streaming input") plus the field names embedded in the
/// Claude Code 2.1.283 binary (`control_request`/`can_use_tool`/`control_response`/`control_cancel_request`).
/// See Docs/research/chat-input.md. Everything received is data: it is parsed, sanitized for display, never executed.
enum ChatWire {
    /// One parsed line of CLI stdout.
    enum Incoming {
        case systemInit(sessionId: String?, model: String?)
        case assistantText(String)
        case toolUse(id: String, name: String, input: [String: Any])
        /// Permission prompt: the CLI blocks the tool call until a `control_response` with the same `requestId` arrives.
        case canUseTool(requestId: String, toolName: String, input: [String: Any], suggestions: [Any], toolUseId: String?)
        case controlCancel(requestId: String)
        case result(isError: Bool, subtype: String, text: String?)
        /// Valid JSON of a type we do not use (user echo, stream_event, rate_limit_event, hook events, ...).
        case ignored
    }

    static let maxLineBytes = 1024 * 1024

    /// nil = not a JSON object / no `type` (malformed).
    static func parse(line: Data) -> Incoming? {
        guard line.count <= maxLineBytes,
              let root = try? JSONSerialization.jsonObject(with: line),
              let obj = root as? [String: Any], let type = obj["type"] as? String else { return nil }
        switch type {
        case "system":
            guard obj["subtype"] as? String == "init" else { return .ignored }
            return .systemInit(sessionId: obj["session_id"] as? String, model: obj["model"] as? String)
        case "assistant":
            // Handled by `assistantParts` (one message can carry several blocks).
            return .ignored
        case "result":
            let subtype = (obj["subtype"] as? String) ?? ""
            let isError = (obj["is_error"] as? Bool) ?? subtype.hasPrefix("error")
            return .result(isError: isError, subtype: subtype, text: obj["result"] as? String)
        case "control_request":
            guard let rid = obj["request_id"] as? String, !rid.isEmpty,
                  let req = obj["request"] as? [String: Any], req["subtype"] as? String == "can_use_tool" else { return .ignored }
            guard let tool = req["tool_name"] as? String else { return nil }
            return .canUseTool(requestId: rid, toolName: tool, input: (req["input"] as? [String: Any]) ?? [:],
                               suggestions: (req["permission_suggestions"] as? [Any]) ?? [],
                               toolUseId: req["tool_use_id"] as? String)
        case "control_cancel_request":
            guard let rid = obj["request_id"] as? String, !rid.isEmpty else { return nil }
            return .controlCancel(requestId: rid)
        default:
            return .ignored
        }
    }

    /// Text and tool_use blocks of an `assistant` line (empty for other lines or sub-agent messages).
    static func assistantParts(line: Data) -> [Incoming] {
        guard line.count <= maxLineBytes,
              let root = try? JSONSerialization.jsonObject(with: line), let obj = root as? [String: Any],
              obj["type"] as? String == "assistant",
              obj["parent_tool_use_id"] == nil || obj["parent_tool_use_id"] is NSNull,
              let msg = obj["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] else { return [] }
        var out: [Incoming] = []
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String, !t.isEmpty { out.append(.assistantText(t)) }
            case "tool_use":
                if let name = b["name"] as? String {
                    out.append(.toolUse(id: (b["id"] as? String) ?? "", name: name, input: (b["input"] as? [String: Any]) ?? [:]))
                }
            default: break
            }
        }
        return out
    }

    // MARK: encoders (one JSON object per line, without the trailing newline)

    static func userMessage(_ text: String) -> Data {
        encode(["type": "user", "message": ["role": "user", "content": text]])
    }

    static func allow(requestId: String, updatedInput: [String: Any], updatedPermissions: [Any]? = nil) -> Data {
        var inner: [String: Any] = ["behavior": "allow", "updatedInput": updatedInput]
        if let updatedPermissions, !updatedPermissions.isEmpty { inner["updatedPermissions"] = updatedPermissions }
        return controlResponse(requestId: requestId, inner)
    }

    static func deny(requestId: String, message: String) -> Data {
        controlResponse(requestId: requestId, ["behavior": "deny", "message": message])
    }

    private static func controlResponse(requestId: String, _ inner: [String: Any]) -> Data {
        encode(["type": "control_response",
                "response": ["subtype": "success", "request_id": requestId, "response": inner] as [String: Any]])
    }

    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
