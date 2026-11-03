import Foundation

/// Buffered, blocking line reader on a socket fd (host channel only; limit `HostProtocol.maxLineBytes`).
/// Not thread safe: one reader thread per connection.
final class HostLineReader: @unchecked Sendable {
    enum Result { case line(Data), eof, tooLong, timeout }

    let fd: Int32
    private var buffer = Data()
    private var scanned = 0
    private let limit: Int
    /// Monotonic time (ns, does not advance during system sleep) of the last chunk received.
    private let lastRxLock = NSLock()
    private var _lastRx: UInt64 = DispatchTime.now().uptimeNanoseconds
    var lastReceive: UInt64 { lastRxLock.lock(); defer { lastRxLock.unlock() }; return _lastRx }

    init(fd: Int32, limit: Int = HostProtocol.maxLineBytes) { self.fd = fd; self.limit = limit }

    /// Blocks until a full line, EOF, an oversize line, or `timeout` seconds without any data (nil = wait forever).
    func next(timeout: TimeInterval? = nil) -> Result {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let nl = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let idx = nl - buffer.startIndex
                let line = Data(buffer.prefix(idx))
                buffer.removeSubrange(buffer.startIndex...nl)
                scanned = 0
                return line.count > limit ? .tooLong : .line(line)
            }
            scanned = buffer.count
            if buffer.count > limit { return .tooLong }
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return .timeout }
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let rc = poll(&p, 1, Int32(min(remaining, 3600) * 1000))
                if rc < 0 { if errno == EINTR { continue }; return .eof }
                if rc == 0 { return .timeout }
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return .eof }
            if n == 0 { return .eof }
            lastRxLock.lock(); _lastRx = DispatchTime.now().uptimeNanoseconds; lastRxLock.unlock()
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// Serialised writer for one connection: whole frames only, never interleaved. Once a write fails or `close()` was called
/// every later write is dropped and `onFailure` has been fired once.
final class HostFrameWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var dead = false
    private let onFailure: @Sendable () -> Void

    init(fd: Int32, onFailure: @escaping @Sendable () -> Void) { self.fd = fd; self.onFailure = onFailure }

    var isDead: Bool { lock.lock(); defer { lock.unlock() }; return dead }

    @discardableResult
    func send(_ frame: Data) -> Bool {
        guard frame.count < HostProtocol.maxLineBytes else { return false }
        lock.lock()
        if dead { lock.unlock(); return false }
        var d = frame; d.append(0x0A)
        let ok = SocketIO.writeAll(fd, d)
        if !ok { dead = true }
        lock.unlock()
        if !ok { onFailure() }
        return ok
    }

    /// Stops all further writes (no fd close; the owner of the fd does that).
    func close() { lock.lock(); dead = true; lock.unlock() }
}

func hostMonotonicNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
