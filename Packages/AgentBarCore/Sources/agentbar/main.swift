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
  agentbar hook --adapter claudeCode|codex|genericCLI|computerUse [--argv JSON]   (reads hook JSON on stdin, or from --argv)
  agentbar watch --session ID             (blocks; prints "pause"/"resume"/"stop" lines as the app sends them; exits 0 after stop,
                                           3 if the app is/gets unreachable)
  agentbar run --session ID [--name N] [--log] -- <cmd> [args...]
                                          (runs cmd; session working -> done/error by exit code; --log forwards stdout lines)

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
    var rc: Int32 = -1
    // ECONNREFUSED is also what a full listen backlog looks like under burst load: retry briefly (max ~0.5 s total).
    // An absent app (ENOENT) or a stale socket fails on the first or last try without noticeable delay.
    for attempt in 0..<5 {
        rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc == 0 || errno != ECONNREFUSED || !FileManager.default.fileExists(atPath: path) { break }
        usleep(UInt32(50_000 * (attempt + 1)))
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
    // `--argv <json>`: payload given as an argument (e.g. Codex `notify`) instead of stdin.
    if let inline = a.one("argv") { input = Data(inline.utf8) }
    while a.one("argv") == nil && input.count <= 4 * 1024 * 1024 {
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

// MARK: watch (command channel app -> CLI)

enum WatchEnd { case stopped, lost, unreachable }

/// Opens a `watch` connection and calls `onEvent` for each command line ("pause", "resume", "stop"). `onConnected` runs once the
/// server confirmed. Returns when stop arrived, the connection broke, or the app is unreachable.
func watchSession(_ session: String, onConnected: () -> Void = {}, onEvent: (String) -> Void) -> WatchEnd {
    let dir = defaultDir()
    guard let token = readToken(dir), let fd = connectSocket(dir) else { return .unreachable }
    defer { close(fd) }
    var tv = timeval(tv_sec: 0, tv_usec: 0)    // the connection is long-lived: no send timeout needed for reading
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    guard var data = try? JSONSerialization.data(withJSONObject: ["op": "watch", "session": session, "token": token], options: [.sortedKeys]) else { return .lost }
    data.append(0x0A)
    guard data.withUnsafeBytes({ write(fd, $0.baseAddress!, $0.count) }) == data.count else { return .lost }
    var buf = Data(); var chunk = [UInt8](repeating: 0, count: 4096)
    var confirmed = false
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n < 0 { if errno == EINTR { continue }; return .lost }
        if n == 0 { return .lost }
        buf.append(contentsOf: chunk[0..<n])
        if buf.count > 64 * 1024 { return .lost }
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[buf.startIndex..<nl]; buf = Data(buf[(nl + 1)...])
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["ok"] as? Bool == true,
                  let ev = o["event"] as? String else { return .lost }
            if ev == "watching" { confirmed = true; onConnected(); continue }
            guard confirmed else { return .lost }
            onEvent(ev)
            if ev == "stop" { return .stopped }
        }
    }
}

func runWatch(_ a: Args) -> Int32 {
    guard need(a, ["session"]) else { return Exit.invalid }
    let end = watchSession(a.one("session")!, onEvent: { out($0 + "\n"); fflush(stdout) })
    switch end {
    case .stopped: return Exit.ok
    case .unreachable: err("agentbar: app not reachable"); return Exit.unreachable
    case .lost: err("agentbar: connection to app lost"); return Exit.unreachable
    }
}

// MARK: run (generic CLI wrapper)

/// Fire-and-forget notifications to the app on a serial queue: a missing or hung app never delays the wrapped command.
/// After the first unreachable result, log lines are dropped (state changes are still retried).
final class Notifier: @unchecked Sendable {
    private let q = DispatchQueue(label: "agentbar.run.notify")
    private let dir = defaultDir()
    private var down = false   // only touched on `q`
    let session: String

    init(session: String) { self.session = session }

    private func send(_ op: String, _ extra: [String: Any], droppable: Bool = false) {
        var r = extra; r["op"] = op; r["session"] = session
        let frozen = UncheckedBox(r)
        q.async { [self] in
            if droppable && down { return }
            if case .reply = roundTrip(frozen.value, dir: dir, replyTimeout: nonBlockingReplyTimeout) { down = false } else { down = true }
        }
    }
    func update(_ extra: [String: Any]) { send("update", extra) }
    func log(_ kind: String, _ text: String) { send("log", ["kind": kind, "text": text], droppable: true) }
    func end() { send("end", [:]) }
    /// Waits (bounded) until everything queued so far was sent.
    func flush(timeout: TimeInterval = 8) {
        let sem = DispatchSemaphore(value: 0)
        q.async { sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
    }
}

nonisolated(unsafe) var runChildPid: pid_t = 0

func runWrapped(_ rawArgs: [String]) -> Int32 {
    guard let sep = rawArgs.firstIndex(of: "--") else { err("agentbar: run needs '-- <cmd>'"); err(usage); return Exit.invalid }
    let cmd = Array(rawArgs[(sep + 1)...])
    guard !cmd.isEmpty, let a = parseArgs(Array(rawArgs[..<sep]).map { $0 == "--log" ? "--log=1" : $0 }),
          let session = a.one("session"), !session.isEmpty else {
        err("agentbar: run needs --session ID and a command after '--'"); return Exit.invalid
    }
    let forwardLines = a.one("log") != nil
    let name = a.one("name") ?? (cmd[0] as NSString).lastPathComponent
    let notifier = Notifier(session: session)
    let shown = cmd.joined(separator: " ")
    let action = "running: " + (shown.count > 120 ? String(shown.prefix(120)) + "…" : shown)
    notifier.update(["name": name, "kind": "genericCLI", "state": "working", "action": action, "supportsStop": true])

    // Signals: reset to default for the child (SIG_IGN would be inherited across exec), handled here via dispatch sources.
    let sigs: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    var defaults = sigset_t(); sigemptyset(&defaults)
    for s in sigs { sigaddset(&defaults, s) }
    var empty = sigset_t(); sigemptyset(&empty)
    posix_spawnattr_setsigdefault(&attr, &defaults)
    posix_spawnattr_setsigmask(&attr, &empty)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    defer { posix_spawnattr_destroy(&attr) }

    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    var pipeFds: [Int32] = [-1, -1]
    if forwardLines {
        guard pipe(&pipeFds) == 0 else { err("agentbar: pipe failed"); return 1 }
        posix_spawn_file_actions_adddup2(&actions, pipeFds[1], 1)
        posix_spawn_file_actions_addclose(&actions, pipeFds[0])
        posix_spawn_file_actions_addclose(&actions, pipeFds[1])
    }

    var pid: pid_t = 0
    let argvC: [UnsafeMutablePointer<CChar>?] = cmd.map { strdup($0) } + [nil]
    defer { for p in argvC { free(p) } }
    let spawnRc = posix_spawnp(&pid, cmd[0], &actions, &attr, argvC, environ)
    if forwardLines { close(pipeFds[1]) }
    guard spawnRc == 0 else {
        if forwardLines { close(pipeFds[0]) }
        let code: Int32 = (spawnRc == ENOENT) ? 127 : 126
        err("agentbar: cannot run '\(cmd[0])': \(String(cString: strerror(spawnRc)))")
        notifier.update(["state": "error", "action": "cannot start: \(cmd[0])", "supportsStop": false])
        notifier.log("error", "cannot start '\(cmd[0])': \(String(cString: strerror(spawnRc)))")
        notifier.flush()
        return code
    }
    runChildPid = pid

    // Forward signals to the child once. Terminal Ctrl-C already reaches the whole foreground process group
    // (including the child), so SIGINT/SIGQUIT are not forwarded again when we are in the foreground of a tty.
    let inForegroundOfTTY = isatty(0) == 1 && tcgetpgrp(0) == getpgrp()
    var sources: [DispatchSourceSignal] = []
    let interrupted = ManagedFlag()
    for s in sigs {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .global())
        src.setEventHandler {
            interrupted.set(s)
            if (s == SIGINT || s == SIGQUIT) && inForegroundOfTTY { return }
            if runChildPid > 0 { kill(runChildPid, s) }
        }
        src.resume()
        sources.append(src)
    }

    // Command channel app -> CLI: stop = SIGTERM to the child (immediately, no confirmation), pause/resume = SIGSTOP/SIGCONT.
    // Re-connects (and re-announces supportsStop) while the child runs, e.g. after an app restart.
    let childAlive = ManagedFlag(); childAlive.set(1)
    let watcher = Thread {
        while childAlive.value != 0 {
            let end = watchSession(session, onConnected: { if childAlive.value != 0 { notifier.update(["supportsStop": true]) } }, onEvent: { ev in
                guard runChildPid > 0 else { return }
                switch ev {
                case "stop": interrupted.set(SIGTERM); kill(runChildPid, SIGTERM); kill(runChildPid, SIGCONT)
                case "pause": kill(runChildPid, SIGSTOP); notifier.update(["action": "paused: " + shown.prefix(100)])
                case "resume": kill(runChildPid, SIGCONT); notifier.update(["action": action])
                default: break
                }
            })
            if end == .stopped { return }
            for _ in 0..<20 where childAlive.value != 0 { usleep(100_000) }
        }
    }
    watcher.start()

    // stdout -> our stdout (verbatim) and, line by line, to the app (bounded).
    var logThread: Thread?
    let logDone = DispatchSemaphore(value: 0)
    if forwardLines {
        let rfd = pipeFds[0]
        let t = Thread {
            var pending = Data(); var chunk = [UInt8](repeating: 0, count: 8192); var sent = 0
            func emit(_ line: Data) {
                guard sent < 300, var text = String(data: line, encoding: .utf8) else { return }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                sent += 1
                notifier.log("action", text.count > 500 ? String(text.prefix(500)) + "…" : text)
            }
            while true {
                let n = read(rfd, &chunk, chunk.count)
                if n < 0 { if errno == EINTR { continue }; break }
                if n == 0 { break }
                FileHandle.standardOutput.write(Data(chunk[0..<n]))
                pending.append(contentsOf: chunk[0..<n])
                while let nl = pending.firstIndex(of: 0x0A) {
                    emit(pending[pending.startIndex..<nl]); pending = Data(pending[(nl + 1)...])
                }
                if pending.count > 8192 { emit(pending); pending = Data() }
            }
            if !pending.isEmpty { emit(pending) }
            close(rfd)
            logDone.signal()
        }
        t.start(); logThread = t
    }

    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 { if errno != EINTR { status = 1 << 8; break } }
    runChildPid = 0
    childAlive.set(0)
    if logThread != nil { _ = logDone.wait(timeout: .now() + 2) }
    for src in sources { src.cancel() }

    let exitCode: Int32
    var sigName: String?
    if (status & 0x7f) == 0 { exitCode = (status >> 8) & 0xff }
    else if (status & 0x7f) != 0x7f { let sg = status & 0x7f; exitCode = 128 + sg; sigName = String(cString: strsignal(sg)) }
    else { exitCode = 1 }

    if exitCode == 0 {
        notifier.log("status", "exit 0")
        notifier.end()
    } else if let sigName, interrupted.value != 0 {
        notifier.log("status", "stopped (\(sigName))")
        notifier.end()
    } else {
        let why = sigName.map { "killed: \($0)" } ?? "exit \(exitCode)"
        notifier.log("error", why)
        notifier.update(["state": "error", "action": why, "supportsStop": false])
    }
    notifier.flush()
    return exitCode
}

final class UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

final class ManagedFlag: @unchecked Sendable {
    private let l = NSLock(); private var v: Int32 = 0
    func set(_ x: Int32) { l.lock(); v = x; l.unlock() }
    var value: Int32 { l.lock(); defer { l.unlock() }; return v }
}

// MARK: Main

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { err(usage); exit(Exit.invalid) }
if cmd == "run" { exit(runWrapped(Array(argv.dropFirst()))) }
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
case "watch": code = runWatch(args)
default: err(usage); code = Exit.invalid
}
exit(code)
