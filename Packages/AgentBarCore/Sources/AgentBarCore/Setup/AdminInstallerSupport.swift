import Foundation
import CryptoKit

// Pure helpers of the admin installer (App/Sources/Setup/AdminInstallerSpec.swift): shell/AppleScript quoting, the
// build-time hash manifest, the status-file lines written by Scripts/setup-agent-user.sh and the privileged
// command line. No system access except reading files for hashing, so everything here is unit-testable.

public enum AdminShell {
    /// POSIX single-quote quoting: the result is one literal word for sh/bash, whatever the input contains.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string literal ("..." with \\ and \" escaped, control characters turned into escapes).
    public static func appleScriptLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    /// Same allow-list as the script (`--owner`): letters, digits, `.`, `_`, `-`, 1...31 chars, no leading `-`.
    public static func isSafeAccountName(_ s: String) -> Bool {
        guard (1...31).contains(s.utf8.count), !s.hasPrefix("-") else { return false }
        return s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2E || c == 0x5F || c == 0x2D
        }
    }
}

public enum AdminInstallerError: Error, Equatable, CustomStringConvertible, Sendable {
    case payloadMissing(String)
    case payloadTampered(String)
    case invalidOwner(String)
    case tokenNotStaged
    case cancelled
    case stagingFailed(String)
    case failed(String)

    public var description: String {
        switch self {
        case .payloadMissing(let m): return "installer payload missing: \(m)"
        case .payloadTampered(let m): return "installer payload does not match its manifest: \(m)"
        case .invalidOwner(let n): return "unsafe account name: \(n)"
        case .tokenNotStaged: return "the Claude token was not staged before the admin step"
        case .cancelled: return "admin authorization was cancelled"
        case .stagingFailed(let m): return "could not verify the root staging copy: \(m)"
        case .failed(let m): return "admin setup failed: \(m)"
        }
    }

    /// Maps the result of `do shell script ... with administrator privileges`.
    /// `code` is NSAppleScript's error number (-128 = cancelled, otherwise the script's exit status).
    public static func classify(code: Int, message: String, lastFailure: String?) -> AdminInstallerError {
        let detail = lastFailure ?? message
        switch code {
        case -128: return .cancelled
        case AdminInstallerSpec.exitStagingShape, AdminInstallerSpec.exitStagingHash: return .stagingFailed(detail)
        default: return .failed(detail.isEmpty ? "exit \(code)" : detail)
        }
    }
}

/// Constants and pure builders shared by the app-side installer and its tests.
public enum AdminInstallerSpec {
    public static let exitStagingShape = 71
    public static let exitStagingHash = 72
    public static let payloadFolder = "AgentSetup"
    public static let statusDirectory = "/Library/Application Support/AgentBar"
    public static let statusFile = "/Library/Application Support/AgentBar/setup-status.jsonl"
    /// Fixed, flat names of the payload (these exact files are hashed, copied and verified).
    public static let payloadFiles = ["agentbar", "agentbar-host", "setup-agent-user.sh", "com.agentbar.host.plist.template"]
    static let scriptName = "setup-agent-user.sh"

    /// The program root runs. Copies each payload file into a fresh root-owned 0700 staging directory, makes it
    /// root:wheel, rejects anything that is not exactly the expected regular files, verifies SHA-256 there (not in
    /// the user-writable bundle: no check/use gap), and only then runs the staged script. Values are quoted
    /// individually; exits 71/72 on staging problems, otherwise the script's own status.
    public static func program(payloadDir: String, manifest: AdminManifest, owner: String, steps: [String],
                               tokenFile: String?, runID: String) throws -> String {
        guard AdminShell.isSafeAccountName(owner) else { throw AdminInstallerError.invalidOwner(owner) }
        var lines = ["set -eu", "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                     "B=\(AdminShell.quote(statusDirectory))",
                     "/usr/bin/install -d -o root -g wheel -m 755 \"$B\"",
                     "S=\"$(/usr/bin/mktemp -d \"$B/staging.XXXXXX\")\"",
                     "trap '/bin/rm -rf \"$S\"' EXIT",
                     "/bin/chmod 700 \"$S\""]
        for name in payloadFiles {
            let src = (payloadDir as NSString).appendingPathComponent(name)
            lines.append("/usr/bin/ditto --norsrc --noextattr --noqtn \(AdminShell.quote(src)) \"$S/\(name)\"")
        }
        lines.append("/usr/sbin/chown -R root:wheel \"$S\"")
        lines.append("/bin/chmod -R go-w \"$S\"")
        lines.append("[ -z \"$(/usr/bin/find \"$S\" -mindepth 1 ! -type f -print)\" ] && [ \"$(/usr/bin/find \"$S\" -mindepth 1 | /usr/bin/wc -l | /usr/bin/tr -d ' ')\" = \(payloadFiles.count) ] || { echo 'staging holds unexpected entries' >&2; exit \(exitStagingShape); }")
        let sums = payloadFiles.compactMap { n in manifest.files[n].map { "\($0)  \(n)" } }
        lines.append("(cd \"$S\" && /usr/bin/printf '%s\\n' \(sums.map(AdminShell.quote).joined(separator: " ")) | /usr/bin/shasum -a 256 -c - >/dev/null) || { echo 'SHA-256 mismatch in staging copy' >&2; exit \(exitStagingHash); }")
        var call = ["/bin/bash", "\"$S/\(scriptName)\"", "--owner", AdminShell.quote(owner),
                    "--steps", AdminShell.quote(steps.joined(separator: ",")), "--run-id", AdminShell.quote(runID),
                    "--host-binary", "\"$S/agentbar-host\"", "--cli-binary", "\"$S/agentbar\""]
        if let t = tokenFile { call += ["--token-file", AdminShell.quote(t)] }
        lines.append(call.joined(separator: " "))
        return lines.joined(separator: "; ")
    }

    /// AppleScript source for the single admin prompt.
    public static func appleScriptSource(program: String) -> String {
        "do shell script \(AdminShell.appleScriptLiteral("/bin/bash -c " + AdminShell.quote(program))) with administrator privileges"
    }
}

// MARK: - Manifest

/// Build-time manifest written by App/Scripts/bundle-cli.sh: `{"version":1,"files":{"name":"sha256hex"}}`.
public struct AdminManifest: Equatable, Sendable {
    public let files: [String: String]

    public init(files: [String: String]) { self.files = files }

    public init(parsing data: Data) throws {
        struct Raw: Decodable { let version: Int; let files: [String: String] }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.version == 1 else {
            throw AdminInstallerError.payloadTampered("manifest unreadable or unsupported version")
        }
        for name in AdminInstallerSpec.payloadFiles {
            guard let h = raw.files[name], Self.isSHA256Hex(h) else {
                throw AdminInstallerError.payloadTampered("manifest lacks a valid hash for \(name)")
            }
        }
        files = raw.files.filter { AdminInstallerSpec.payloadFiles.contains($0.key) }
    }

    public static func isSHA256Hex(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Early check in the app (fast, friendly error). The authoritative check runs on the root-owned copy.
    public func verify(directory: URL) throws {
        let fm = FileManager.default
        for name in AdminInstallerSpec.payloadFiles {
            let url = directory.appendingPathComponent(name)
            var isLink = false
            if let t = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType { isLink = (t == .typeSymbolicLink) }
            guard !isLink, let data = try? Data(contentsOf: url) else { throw AdminInstallerError.payloadMissing(name) }
            guard Self.sha256Hex(of: data) == files[name] else { throw AdminInstallerError.payloadTampered(name) }
        }
    }
}

// MARK: - Status file

/// One JSON line of the script's status file.
public struct AdminStatusLine: Equatable, Sendable {
    public var seq: Int
    public var run: String
    public var step: String
    public var state: String   // running | info | done | warn | failed
    public var msg: String

    public init(seq: Int, run: String, step: String, state: String, msg: String) {
        self.seq = seq; self.run = run; self.step = step; self.state = state; self.msg = msg
    }

    public static func parse(_ line: String) -> AdminStatusLine? {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let seq = o["seq"] as? Int, let run = o["run"] as? String, let step = o["step"] as? String,
              let state = o["state"] as? String, let msg = o["msg"] as? String else { return nil }
        return AdminStatusLine(seq: seq, run: run, step: step, state: state, msg: msg)
    }

    /// All well-formed lines of this run, in file order (foreign runs and torn/garbled lines are dropped).
    public static func lines(in text: String, run: String) -> [AdminStatusLine] {
        text.split(whereSeparator: \.isNewline).compactMap { parse(String($0)) }.filter { $0.run == run }
    }

    public var isFailure: Bool { state == "failed" }
    public var progressText: String { msg }
    public var setupStep: SetupStep? { SetupStep(rawValue: step) }
}
