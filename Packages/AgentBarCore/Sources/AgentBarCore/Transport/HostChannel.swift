import Foundation

extension HostClient {
    /// Transport entry for `{"token","op":"host","protocol":1,"user","uid","workspaceRoot","agents"}` from an authenticated
    /// agent-role peer. Returns an error reply for the transport to send, or nil once the connection was served and has ended
    /// (the transport must then not reply). After the `ready` line both sides speak `HostCommand` / `HostEvent` frames
    /// (max 1 MiB per line). The hello is display data only; identity comes from the kernel (`peerUid`), not from the hello.
    func acceptHost(_ req: [String: Any], fd: Int32, peerUid: uid_t?) -> [String: Any]? {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard (req["protocol"] as? Int) == HostProtocol.version else { return fail("unsupported protocol") }
        guard let user = req["user"] as? String, Self.isDisplaySafe(user, max: 32),
              let root = req["workspaceRoot"] as? String, Self.isDisplaySafe(root, max: 256) else { return fail("invalid hello") }
        var agents: [String: String] = [:]
        if let raw = req["agents"] {
            guard let d = raw as? [String: Any], d.count <= 8 else { return fail("invalid hello") }
            for (k, v) in d {
                guard let s = v as? String, Self.isDisplaySafe(k, max: 32), Self.isDisplaySafe(s, max: 256) else { return fail("invalid hello") }
                agents[k] = s
            }
        }
        let uid = peerUid.map { Int($0) } ?? ((req["uid"] as? Int) ?? -1)
        let info = Info(user: user, uid: uid, workspaceRoot: root, agents: agents)
        let served = serve(fd: fd, info: info) { fd in
            guard var d = try? JSONEncoder().encode(HostReady()) else { return false }
            d.append(0x0A)
            return SocketIO.writeAll(fd, d)
        }
        return served ? nil : fail("host already connected")
    }

    /// Non-empty, bounded, no control/format/separator characters (the text is shown in the UI).
    static func isDisplaySafe(_ s: String, max: Int) -> Bool {
        guard !s.isEmpty, s.count <= max else { return false }
        return s.unicodeScalars.allSatisfy { u in
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse: return false
            default: return true
            }
        }
    }
}
