import Foundation

// agentbar CLI. Exit codes: 0 ok/answered, 2 ask timeout, 3 app not reachable, 4 unauthorized/invalid, 1 cancelled.
// Standalone on purpose: Foundation only, so it starts fast and has no GUI dependencies.

setvbuf(stdout, nil, _IOFBF, 0)

func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

enum Exit { static let ok: Int32 = 0, cancelled: Int32 = 1, timeout: Int32 = 2, unreachable: Int32 = 3, invalid: Int32 = 4 }

let usage = """
usage:
  agentbar update --session ID [--name N] [--kind K] [--state S] [--action TEXT] [--supports-stop]
  agentbar ask --session ID --type approval|question|info --text T [--option id:label[:style]]... [--timeout SEC] [--default ID]
  agentbar log --session ID --kind K --text T
  agentbar end --session ID
  agentbar remove --session ID            (removes the session; its pending asks return "cancelled")
  agentbar hook --adapter claudeCode      (reads hook JSON on stdin)

"""

// MARK: Arguments

struct Args {
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    func one(_ k: String) -> String? { values[k]?.last }
}

func parseArgs(_ argv: [String]) -> Args? {
    var a = Args()
    let boolFlags: Set<String> = ["supports-stop"]
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        guard arg.hasPrefix("--"), arg.count > 2 else { return nil }
        var key = String(arg.dropFirst(2))
        var val: String?
        if let eq = key.firstIndex(of: "=") { val = String(key[key.index(after: eq)...]); key = String(key[..<eq]) }
        if boolFlags.contains(key) && val == nil { a.flags.insert(key); i += 1; continue }
        if val == nil { i += 1; guard i < argv.count else { return nil }; val = argv[i] }
        a.values[key, default: []].append(val!)
        i += 1
    }
    return a
}

// MARK: Connection

func defaultDir() -> String {
    if let d = ProcessInfo.processInfo.environment["AGENTBAR_DIR"], !d.isEmpty { return d }
    return NSHomeDirectory() + "/Library/Application Support/AgentBar"
}

func readToken(_ dir: String) -> String? {
    guard let d = FileManager.default.contents(atPath: dir + "/token"),
          let s = String(data: d, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

let connectTimeout: TimeInterval = 5
let nonBlockingReplyTimeout: TimeInterval = 5
let askGrace: TimeInterval = 5
let hookBlockingTimeout: TimeInterval = 130

func connectSocket(_ dir: String) -> Int32? {
    let path = dir + "/agentbar.sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) } }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    // Non-blocking connect bounded by connectTimeout so a wedged server (full backlog) can never hang a hook.
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if rc != 0 && (errno == EINPROGRESS || errno == EAGAIN) {
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&p, 1, Int32(connectTimeout * 1000))
        var soErr: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        rc = (pr > 0 && soErr == 0) ? 0 : -1
    }
    if rc != 0 { close(fd); return nil }
    _ = fcntl(fd, F_SETFL, flags)
    var tv = timeval(tv_sec: Int(connectTimeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

enum RoundTrip { case reply([String: Any]), unreachable, badReply, timedOut }

/// Sends one request line and reads one reply line. `replyTimeout` bounds the wait for the reply
/// (nil = wait as long as the server keeps the ask open).
func roundTrip(_ request: [String: Any], dir: String, replyTimeout: TimeInterval?) -> RoundTrip {
    guard let token = readToken(dir), let fd = connectSocket(dir) else { return .unreachable }
    defer { close(fd) }
    var req = request
    req["token"] = token
    guard var data = try? JSONSerialization.data(withJSONObject: req, options: [.sortedKeys]) else { return .badReply }
    data.append(0x0A)
    // A failed write (e.g. server rejected an oversized line early) still allows reading its error reply.
    data.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n < 0 { if errno == EINTR { continue }; break }
            off += n
        }
    }
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    let deadline = replyTimeout.map { Date().addingTimeInterval($0) }
    while !buf.contains(0x0A) {
        var waitMs: Int32 = -1
        if let deadline {
            let rem = deadline.timeIntervalSinceNow
            if rem <= 0 { return .timedOut }
            waitMs = Int32(min(rem, 3600) * 1000) + 1
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, waitMs)
        if pr < 0 { if errno == EINTR { continue }; break }
        if pr == 0 { continue }
        let n = read(fd, &chunk, chunk.count)
        if n < 0 { if errno == EINTR { continue }; break }
        if n == 0 { break }
        buf.append(contentsOf: chunk[0..<n])
        if buf.count > 8 * 1024 * 1024 { break }
    }
    let line = buf.prefix(while: { $0 != 0x0A })
    guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
        return buf.isEmpty ? .unreachable : .badReply
    }
    return .reply(obj)
}

func printJSON(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) { out(s + "\n") }
}

// MARK: Commands

func simpleCommand(_ op: String, _ req: [String: Any]) -> Int32 {
    var r = req; r["op"] = op
    switch roundTrip(r, dir: defaultDir(), replyTimeout: nonBlockingReplyTimeout) {
    case .unreachable: err("agentbar: app not reachable"); return Exit.unreachable
    case .timedOut: err("agentbar: app not responding"); return Exit.unreachable
    case .badReply: err("agentbar: invalid reply"); return Exit.invalid
    case .reply(let obj):
        if obj["ok"] as? Bool == true { return Exit.ok }
        err("agentbar: \(obj["error"] as? String ?? "error")"); return Exit.invalid
    }
}

func need(_ a: Args, _ keys: [String]) -> Bool {
    for k in keys where a.one(k) == nil { err("agentbar: missing --\(k)"); return false }
    return true
}

func runAsk(_ a: Args) -> Int32 {
    guard need(a, ["session", "type", "text"]) else { return Exit.invalid }
    var req: [String: Any] = ["op": "ask", "session": a.one("session")!, "type": a.one("type")!, "text": a.one("text")!]
    var options: [[String: String]] = []
    for spec in a.values["option"] ?? [] {
        let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { err("agentbar: bad --option '\(spec)' (id:label[:style])"); return Exit.invalid }
        var o = ["id": parts[0], "label": parts[1]]
        if parts.count == 3 { o["style"] = parts[2] }
        options.append(o)
    }
    if !options.isEmpty { req["options"] = options }
    if let t = a.one("timeout") { guard let n = Int(t), n >= 0 else { err("agentbar: bad --timeout"); return Exit.invalid }; req["timeout"] = n }
    if let d = a.one("default") { req["default"] = d }
    // Bounded by the request timeout + grace; without --timeout the ask waits for the user indefinitely.
    let bound = (req["timeout"] as? Int).map { TimeInterval($0) + askGrace }
    switch roundTrip(req, dir: defaultDir(), replyTimeout: bound) {
    case .unreachable: err("agentbar: app not reachable"); return Exit.unreachable
    case .timedOut: err("agentbar: no answer from app"); return Exit.unreachable
    case .badReply: err("agentbar: invalid reply"); return Exit.invalid
    case .reply(let obj):
        printJSON(obj)
        guard obj["ok"] as? Bool == true else { return Exit.invalid }
        switch obj["reason"] as? String {
        case "answered": return Exit.ok
        case "timeout": return Exit.timeout
        default: return Exit.cancelled
        }
    }
}

/// Hook mode must never block the agent or fail loudly: any problem prints nothing and exits 0.
func runHook(_ a: Args) -> Int32 {
    guard let adapter = a.one("adapter") else { return 0 }
    var input = Data()
    while input.count <= 4 * 1024 * 1024 {
        let d = FileHandle.standardInput.availableData
        if d.isEmpty { break }
        input.append(d)
    }
    guard let payload = try? JSONSerialization.jsonObject(with: input, options: [.fragmentsAllowed]) else { return 0 }
    let req: [String: Any] = ["op": "payload", "adapter": adapter, "payload": payload]
    // Only PermissionRequest blocks for a decision; every other event is fire-and-forget (5 s).
    let blocking = ((payload as? [String: Any])?["hook_event_name"] as? String) == "PermissionRequest"
    guard case .reply(let obj) = roundTrip(req, dir: defaultDir(), replyTimeout: blocking ? hookBlockingTimeout : nonBlockingReplyTimeout),
          obj["ok"] as? Bool == true, let output = obj["output"] as? String, !output.isEmpty else { return 0 }
    out(output)
    return 0
}

// MARK: Main

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { err(usage); exit(Exit.invalid) }
guard let args = parseArgs(Array(argv.dropFirst())) else {
    if cmd == "hook" { exit(0) }
    err(usage); exit(Exit.invalid)
}

let code: Int32
switch cmd {
case "update":
    if need(args, ["session"]) {
        var r: [String: Any] = ["session": args.one("session")!]
        for (flag, key) in [("name", "name"), ("kind", "kind"), ("state", "state"), ("action", "action")] {
            if let v = args.one(flag) { r[key] = v }
        }
        if args.flags.contains("supports-stop") { r["supportsStop"] = true }
        code = simpleCommand("update", r)
    } else { code = Exit.invalid }
case "ask": code = runAsk(args)
case "log":
    code = need(args, ["session", "kind", "text"])
        ? simpleCommand("log", ["session": args.one("session")!, "kind": args.one("kind")!, "text": args.one("text")!])
        : Exit.invalid
case "end":
    code = need(args, ["session"]) ? simpleCommand("end", ["session": args.one("session")!]) : Exit.invalid
case "remove":
    code = need(args, ["session"]) ? simpleCommand("remove", ["session": args.one("session")!]) : Exit.invalid
case "hook": code = runHook(args)
default: err(usage); code = Exit.invalid
}
exit(code)
