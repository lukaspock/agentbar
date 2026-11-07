import Foundation

public enum ChatError: Error, Equatable, Sendable {
    case invalidConfig(String)
    case notRunning
    case emptyText
    case textTooLong
    case alreadyStarted
    case spawnFailed(String)
}

/// Continue an existing claude session (`--resume <id> --fork-session`) instead of starting an empty conversation.
/// Always a FORK: resuming without a fork would interleave this process's messages into the transcript of the open
/// terminal session. `fork == false` is rejected by `ChatConfig.launchSpec`. Local only (transcripts live in the
/// owner's ~/.claude); rejected for the agent-user host.
public struct ChatResume: Sendable, Equatable {
    public var sessionId: String
    public var fork: Bool
    /// Display name of the source session (for the "Forked from <name>" note).
    public var sourceName: String?
    public init(sessionId: String, fork: Bool = true, sourceName: String? = nil) {
        self.sessionId = sessionId; self.fork = fork; self.sourceName = sourceName
    }
    public static let maxIdLength = 64
    /// Strict: only `[A-Za-z0-9-]`, 1...64 chars, must not start with `-`. The id is passed as one argv element, never through a shell.
    public static func isValidSessionId(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= maxIdLength, !s.hasPrefix("-") else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
    }
}

public extension AgentSession {
    /// "Continue in panel" is offered only for Claude Code hook sessions with a valid claude session id and a known
    /// absolute working directory (the fork must start where the transcript lives).
    var canContinueInPanel: Bool {
        kind == .claudeCode && ChatResume.isValidSessionId(id) && (workingDirectory?.hasPrefix("/") ?? false)
    }
}

/// Configuration of one chat session (one `claude` process).
public struct ChatConfig: Sendable {
    /// Permission modes that keep prompts on the host (AgentBar). `bypassPermissions`/`auto` are deliberately not offered.
    public enum PermissionMode: String, Sendable { case manual, acceptEdits, plan, dontAsk }

    /// Absolute path of the `claude` executable.
    public var executable: URL
    /// REQUIRED and explicit: the agent works (and may write) here. Must exist, must not be `/`.
    public var workingDirectory: URL
    /// Store session id; default `chat-<8 hex>`.
    public var sessionId: String?
    /// Display name; default = directory name.
    public var name: String?
    public var model: String?
    public var maxBudgetUSD: Double?
    /// `--tools` list (e.g. ["Read","Grep"]); nil = claude default. Entries must not start with `-` or contain `,`.
    public var tools: [String]?
    /// nil = claude default (prompts for everything not allowed by settings).
    public var permissionMode: PermissionMode?
    /// Environment variables copied from the app's environment (all others are dropped).
    public var passthroughEnvironment: [String]
    /// Additional fixed variables for the child (win over passthrough).
    public var extraEnvironment: [String: String]
    /// No output and no pending approval for this long while working => process is killed and the session errors. nil = off.
    public var idleTimeout: TimeInterval?
    public var idleCheckInterval: TimeInterval
    /// SIGTERM -> SIGKILL grace on stop.
    public var killGrace: TimeInterval
    /// Non-nil = the process runs under the agent user via the host (`RemoteChatProcess`): the workspace NAME below the agent's
    /// work root. `executable`/`workingDirectory` are then display-only placeholders, no local file checks happen, and the
    /// child environment is empty (the host builds its own). Use `ChatConfig.remote(...)`.
    public var remoteWorkspace: String?
    /// Non-nil = continue that claude session as a fork (local only).
    public var resume: ChatResume?

    public static let defaultPassthrough = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR",
                                            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                                            "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN",
                                            "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy"]

    public init(executable: URL, workingDirectory: URL, sessionId: String? = nil, name: String? = nil,
                model: String? = nil, maxBudgetUSD: Double? = nil, tools: [String]? = nil,
                permissionMode: PermissionMode? = nil, passthroughEnvironment: [String] = ChatConfig.defaultPassthrough,
                extraEnvironment: [String: String] = [:], idleTimeout: TimeInterval? = 1800,
                idleCheckInterval: TimeInterval = 5, killGrace: TimeInterval = 2, remoteWorkspace: String? = nil,
                resume: ChatResume? = nil) {
        self.resume = resume
        self.executable = executable; self.workingDirectory = workingDirectory; self.sessionId = sessionId
        self.name = name; self.model = model; self.maxBudgetUSD = maxBudgetUSD; self.tools = tools
        self.permissionMode = permissionMode; self.passthroughEnvironment = passthroughEnvironment
        self.extraEnvironment = extraEnvironment; self.idleTimeout = idleTimeout
        self.idleCheckInterval = idleCheckInterval; self.killGrace = killGrace; self.remoteWorkspace = remoteWorkspace
    }

    /// Config for a chat that runs under the agent user. `workspaceRoot` (from `HostClient.Info`) only makes the displayed
    /// cwd of approval cards truthful; it is never used to touch the file system.
    public static func remote(workspace: String, workspaceRoot: String? = nil, sessionId: String? = nil, name: String? = nil,
                              model: String? = nil, maxBudgetUSD: Double? = nil, tools: [String]? = nil,
                              permissionMode: PermissionMode? = nil, idleTimeout: TimeInterval? = 1800,
                              idleCheckInterval: TimeInterval = 5, killGrace: TimeInterval = 2) -> ChatConfig {
        let shown = (workspaceRoot ?? "/agent-workspaces") + "/" + workspace
        return ChatConfig(executable: URL(fileURLWithPath: "/agent-host/claude"), workingDirectory: URL(fileURLWithPath: shown, isDirectory: true),
                          sessionId: sessionId, name: name ?? workspace, model: model, maxBudgetUSD: maxBudgetUSD, tools: tools,
                          permissionMode: permissionMode, passthroughEnvironment: [], extraEnvironment: [:],
                          idleTimeout: idleTimeout, idleCheckInterval: idleCheckInterval, killGrace: killGrace,
                          remoteWorkspace: workspace)
    }

    /// Typical install locations of the CLI (first existing executable wins); nil if none.
    public static func locateClaude(home: String = NSHomeDirectory()) -> URL? {
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Validates and builds the launch spec. `environment` is the source for `passthroughEnvironment`.
    public func launchSpec(environment source: [String: String] = ProcessInfo.processInfo.environment) throws -> ChatLaunchSpec {
        let dir = workingDirectory.standardizedFileURL
        if let ws = remoteWorkspace {
            guard HostProtocol.isValidWorkspaceName(ws) else { throw ChatError.invalidConfig("invalid workspace name") }
        } else {
            guard executable.isFileURL, executable.path.hasPrefix("/") else { throw ChatError.invalidConfig("executable must be an absolute path") }
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ChatError.invalidConfig("executable not found or not executable") }
            var isDir: ObjCBool = false
            guard dir.isFileURL, FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                throw ChatError.invalidConfig("working directory does not exist")
            }
            guard dir.path != "/" else { throw ChatError.invalidConfig("working directory must not be /") }
        }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if let model {
            guard Self.safeToken(model, extra: "[]") else { throw ChatError.invalidConfig("invalid model") }
            args += ["--model", model]
        }
        if let maxBudgetUSD {
            guard maxBudgetUSD > 0, maxBudgetUSD <= 1000 else { throw ChatError.invalidConfig("invalid budget") }
            args += ["--max-budget-usd", String(maxBudgetUSD)]
        }
        if let tools {
            guard !tools.isEmpty, tools.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains(",") && !$0.contains("\n") }) else {
                throw ChatError.invalidConfig("invalid tools")
            }
            args += ["--tools", tools.joined(separator: ",")]
        }
        if let permissionMode { args += ["--permission-mode", permissionMode.rawValue] }
        if let resume {
            guard remoteWorkspace == nil else { throw ChatError.invalidConfig("resume is only possible for local chats") }
            guard resume.fork else { throw ChatError.invalidConfig("resume must fork the session") }
            guard ChatResume.isValidSessionId(resume.sessionId) else { throw ChatError.invalidConfig("invalid session id") }
            args += ["--resume", resume.sessionId, "--fork-session"]
        }
        if let ws = remoteWorkspace {
            // Remote: structured request only. The environment of the child is built by the host, never by the app.
            let remote = RemoteLaunch(workspace: ws, model: model, maxBudgetUSD: maxBudgetUSD, tools: tools, permissionMode: permissionMode?.rawValue)
            return ChatLaunchSpec(executable: executable, arguments: args, workingDirectory: dir, environment: [:], remote: remote)
        }
        var env: [String: String] = [:]
        for k in passthroughEnvironment { if let v = source[k] { env[k] = v } }
        for (k, v) in extraEnvironment {
            guard Self.safeToken(k, extra: "") else { throw ChatError.invalidConfig("invalid environment name") }
            env[k] = v
        }
        return ChatLaunchSpec(executable: executable, arguments: args, workingDirectory: dir, environment: env)
    }

    private static func safeToken(_ s: String, extra: String) -> Bool {
        guard !s.isEmpty, s.count <= 100, !s.hasPrefix("-") else { return false }
        return s.unicodeScalars.allSatisfy { ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) || extra.unicodeScalars.contains($0)) }
    }
}
