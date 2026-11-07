import Foundation
import AgentBarCore

/// Runs a script text as root with ONE macOS admin prompt. Abstracted so the installer can be tested without a prompt.
protocol AdminScriptExecuting: Sendable {
    /// Executes AppleScript source; returns stdout. Throws `AdminScriptFailure` on error.
    func execute(appleScript: String) throws -> String
}

struct AdminScriptFailure: Error { let code: Int; let message: String }

/// `NSAppleScript` with `do shell script ... with administrator privileges`. Call from a background thread only.
struct AppleScriptExecutor: AdminScriptExecuting {
    func execute(appleScript: String) throws -> String {
        guard let script = NSAppleScript(source: appleScript) else { throw AdminScriptFailure(code: -1, message: "invalid script") }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            throw AdminScriptFailure(code: (err[NSAppleScript.errorNumber] as? Int) ?? -1,
                                     message: (err[NSAppleScript.errorMessage] as? String) ?? "unknown error")
        }
        return result.stringValue ?? ""
    }
}

/// The app side of the single privileged block (`SetupAdminBlock`). Flow: verify the bundled payload against its
/// build-time manifest, build one root program (copy to a root-owned staging dir, re-verify SHA-256 there, run the
/// staged `setup-agent-user.sh`), run it with one admin prompt on a background thread and relay the script's status
/// file (JSON lines, root-owned) as progress. The token (if part of the block) is only a path to a short-lived 0600
/// file; the script moves it into the agent home and deletes the source. See Docs/PLAN-agent-user.md "Admin-Installer".
struct AdminInstaller: SetupAdminBlock {
    var payloadDirectory: URL
    var owner: String
    /// Path of the staged token file (phase 1 result), nil when none was acquired.
    var tokenFile: @Sendable () -> URL?
    var statusFile: String
    var executor: AdminScriptExecuting

    init(payloadDirectory: URL? = nil, owner: String = NSUserName(), tokenFile: @escaping @Sendable () -> URL? = { nil },
         statusFile: String = AdminInstallerSpec.statusFile,
         executor: AdminScriptExecuting = AppleScriptExecutor()) {
        self.payloadDirectory = payloadDirectory
            ?? (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/")).appendingPathComponent(AdminInstallerSpec.payloadFolder, isDirectory: true)
        self.owner = owner; self.tokenFile = tokenFile
        self.statusFile = statusFile; self.executor = executor
    }

    func run(steps: [SetupStep], progress: @Sendable (String) -> Void) async throws {
        let adminSteps = steps.filter { $0.isAdminStep || $0 == .claudeToken }
        guard !adminSteps.isEmpty else { return }
        let token = tokenFile()
        defer { if let token { try? FileManager.default.removeItem(at: token) } }   // the script deletes it too
        if adminSteps.contains(.claudeToken), token == nil { throw AdminInstallerError.tokenNotStaged }

        let manifestURL = payloadDirectory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw AdminInstallerError.payloadMissing("manifest.json") }
        let manifest = try AdminManifest(parsing: data)
        try manifest.verify(directory: payloadDirectory)

        let runID = UUID().uuidString
        let program = try AdminInstallerSpec.program(
            payloadDir: payloadDirectory.path, manifest: manifest, owner: owner, steps: adminSteps.map(\.rawValue),
            tokenFile: adminSteps.contains(.claudeToken) ? token?.path : nil, runID: runID)
        let source = AdminInstallerSpec.appleScriptSource(program: program)

        progress("Waiting for administrator authorization")
        let (outcome, lines): (Result<String, AdminScriptFailure>, [AdminStatusLine]) = await withoutActuallyEscaping(progress) { relayProgress in
            let poller = Task.detached { [statusFile] () -> Int in
                var seen = 0
                while !Task.isCancelled {
                    seen = Self.relay(statusFile: statusFile, runID: runID, from: seen, progress: relayProgress)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                return seen
            }
            let outcome: Result<String, AdminScriptFailure> = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: .success(try executor.execute(appleScript: source))) }
                    catch let f as AdminScriptFailure { cont.resume(returning: .failure(f)) }
                    catch { cont.resume(returning: .failure(AdminScriptFailure(code: -1, message: "\(error)"))) }
                }
            }
            poller.cancel()
            let seen = await poller.value
            _ = Self.relay(statusFile: statusFile, runID: runID, from: seen, progress: relayProgress)   // final flush
            return (outcome, Self.readLines(statusFile: statusFile, runID: runID))
        }

        if case .failure(let f) = outcome {
            throw AdminInstallerError.classify(code: f.code, message: Self.trimmed(f.message),
                                               lastFailure: lines.last(where: \.isFailure)?.msg)
        }
        if let failed = lines.last(where: \.isFailure) { throw AdminInstallerError.failed(failed.msg) }
    }

    // MARK: status file

    static func readLines(statusFile: String, runID: String) -> [AdminStatusLine] {
        guard let data = FileManager.default.contents(atPath: statusFile) else { return [] }
        return AdminStatusLine.lines(in: String(decoding: data, as: UTF8.self), run: runID)
    }

    /// Reports lines after the first `seen` ones; returns the new count.
    static func relay(statusFile: String, runID: String, from seen: Int, progress: @Sendable (String) -> Void) -> Int {
        let lines = readLines(statusFile: statusFile, runID: runID)
        guard lines.count > seen else { return seen }
        for l in lines[seen...] { progress(l.progressText) }
        return lines.count
    }

    private static func trimmed(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)) }
}
