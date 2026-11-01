import Foundation

/// Thin POSIX helpers. Transport choice: POSIX sockets + one thread per connection. Network.framework's
/// NWListener cannot bind AF_UNIX paths with explicit permissions, and poll() on the raw fd gives exact
/// disconnect detection while a request is waiting for an answer.
enum SocketIO {
    static func withSockaddr<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, len) }
        }
    }

    static func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setCloexec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
    }

    /// Constant-time comparison (length difference is folded into the result, not short-circuited).
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = UInt32(truncatingIfNeeded: a.count ^ b.count)
        for i in 0..<a.count { diff |= UInt32(a[i] ^ (i < b.count ? b[i] : 0)) }
        return diff == 0
    }
}

/// Bridges a store callback (main actor) to a blocking connection thread via a self-pipe.
final class ResponseWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentResponse?
    private var fds: [Int32] = [-1, -1]

    init() {
        pipe(&fds)
        SocketIO.setCloexec(fds[0]); SocketIO.setCloexec(fds[1])
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
    }
    deinit { close(fds[0]); close(fds[1]) }

    func deliver(_ r: AgentResponse) {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return }
        value = r
        var b: UInt8 = 1
        _ = write(fds[1], &b, 1)
    }

    private func current() -> AgentResponse? { lock.lock(); defer { lock.unlock() }; return value }

    enum Outcome { case response(AgentResponse), disconnected }

    /// Blocks until the store resolves the request or the peer closes the connection.
    func wait(clientFd: Int32) -> Outcome {
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            if let r = current() { return .response(r) }
            var pfds = [pollfd(fd: clientFd, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)]
            let rc = poll(&pfds, 2, -1)
            if rc < 0 { if errno == EINTR { continue }; return .disconnected }
            if let r = current() { return .response(r) }
            if pfds[0].revents != 0 {
                let n = read(clientFd, &buf, buf.count)   // discard anything sent while waiting
                if n == 0 { return .disconnected }
                if n < 0 && errno != EINTR && errno != EAGAIN { return .disconnected }
            }
        }
    }
}
