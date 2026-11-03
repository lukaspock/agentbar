import Foundation

// Personalization models (names, colors, themes, bots). Owner-side app knowledge only: nothing here is ever derived
// from agent output, and nothing here is part of the frozen Contract model. See Docs/PLAN-personalization.md.

/// Validated "#RRGGBB" color helpers. Colors are stored as upper-case hex strings, never as free text.
public enum HexColor {
    /// Returns the normalized "#RRGGBB" (upper-case) for "#rrggbb"/"rrggbb", else nil.
    public static func normalize(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.utf8.count == 6, t.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return "#" + t.uppercased()
    }

    /// Hex from 0...1 components (rounded, clamped).
    public static func make(red: Double, green: Double, blue: Double) -> String {
        func c(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", c(red), c(green), c(blue))
    }

    /// 0...1 components of an already validated hex, nil if invalid.
    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard let n = normalize(hex), let v = UInt32(n.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

/// Sanitizers for owner-typed text. They reuse the adapter's display sanitizer (controls, bidi/format characters,
/// Zalgo clusters become U+FFFD or are dropped), then cap the length in characters.
public enum PreferenceText {
    public static let maxNameLength = 40
    public static let maxSkillLength = 200
    public static let maxStartPromptLength = 8000
    public static let maxBlobNameLength = 24

    /// Single-line display name. Empty after cleaning => nil.
    public static func name(_ s: String?) -> String? { line(s, max: maxNameLength) }

    public static func skill(_ s: String?) -> String? { line(s, max: maxSkillLength) }

    /// Multi-line start prompt (newlines kept, at most two in a row). Empty => nil.
    public static func startPrompt(_ s: String?) -> String? {
        guard let s else { return nil }
        let clean = ClaudeCodeAdapter.multiLine(s)
        let capped = String(clean.prefix(maxStartPromptLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    /// Blob kind names are plain ASCII identifiers (the core does not know the UI's BlobKind enum).
    public static func blobKindName(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.utf8.count <= maxBlobNameLength,
              s.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }) else { return nil }
        return s
    }

    public static let maxFolderLength = 1024
    public static let maxWorkspaceLength = 64
    public static let maxSkillCommandLength = 64

    /// Absolute local folder path (a leading "~" is expanded). Rejects relative paths, ".." components, control/format
    /// characters and over-long input instead of rewriting them; a trailing "/" is dropped. Empty => nil.
    public static func folderPath(_ s: String?) -> String? {
        guard let s else { return nil }
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "~" || t.hasPrefix("~/") { t = (t as NSString).expandingTildeInPath }
        guard t.hasPrefix("/"), t.utf8.count <= maxFolderLength, ClaudeCodeAdapter.singleLine(t) == t,
              !t.split(separator: "/", omittingEmptySubsequences: true).contains("..") else { return nil }
        while t.count > 1, t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// Name of an agent-user workspace folder (same rule as the host: ASCII letters, digits, dot, dash, underscore;
    /// at most 64; no leading dot). The host validates again, this is only the owner-side pre-check.
    public static func workspaceName(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.utf8.count <= maxWorkspaceLength, !s.hasPrefix("."),
              s.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 46 || $0 == 45 || $0 == 95 })
        else { return nil }
        return s
    }

    /// Skill name as it is put after the slash of the first message: only `[A-Za-z0-9:_-]` survives (a leading "/"
    /// is dropped first), everything else is removed. Empty after cleaning => nil.
    public static func skillCommandName(_ s: String?) -> String? {
        guard let s else { return nil }
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("/") { t.removeFirst() }
        let kept = t.utf8.filter { ($0 >= 48 && $0 <= 58) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45 }
        let name = String(decoding: kept.prefix(maxSkillCommandLength), as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    private static func line(_ s: String?, max: Int) -> String? {
        guard let s else { return nil }
        let clean = ClaudeCodeAdapter.singleLine(s).trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(clean.prefix(max)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Only replacement characters left (input was all control/format scalars): treat as empty.
        return capped.isEmpty || capped.unicodeScalars.allSatisfy({ $0 == "\u{FFFD}" || $0 == " " }) ? nil : capped
    }
}

/// Optional display name and color for a session or an agent type. nil fields fall through to the next level.
public struct AgentAppearance: Codable, Sendable, Equatable {
    public var displayName: String?
    public var colorHex: String?

    public init(displayName: String? = nil, colorHex: String? = nil) {
        self.displayName = displayName
        self.colorHex = colorHex
    }

    public var isEmpty: Bool { displayName == nil && colorHex == nil }

    /// Same value with name/color cleaned; invalid color is dropped.
    func sanitized() -> AgentAppearance {
        AgentAppearance(displayName: PreferenceText.name(displayName), colorHex: colorHex.flatMap(HexColor.normalize))
    }
}

public enum MascotEyeStyle: String, Codable, Sendable, CaseIterable { case round, pill, sleepy, happy }

public enum MascotAccessory: String, Codable, Sendable, CaseIterable { case none, hat, glasses, bow, antenna }

/// The owner's own mascot, shown by the bar while no agent session exists. Owner-side app knowledge only.
public struct MascotAppearance: Codable, Sendable, Equatable {
    public static let defaultName = "Blobby"
    public static let defaultBodyKindName = "circle"
    public static let defaultColorHex = "#9E9BFF"
    public static let standard = MascotAppearance()

    public var name: String
    /// Name of a UI blob shape ("circle", "cloud", ...); the core does not know the UI's BlobKind enum.
    public var bodyKindName: String
    public var colorHex: String
    public var eyeStyle: MascotEyeStyle
    public var accessory: MascotAccessory

    public init(name: String = MascotAppearance.defaultName, bodyKindName: String = MascotAppearance.defaultBodyKindName,
                colorHex: String = MascotAppearance.defaultColorHex, eyeStyle: MascotEyeStyle = .round,
                accessory: MascotAccessory = .none) {
        self.name = name; self.bodyKindName = bodyKindName; self.colorHex = colorHex
        self.eyeStyle = eyeStyle; self.accessory = accessory
    }

    // Lenient decoding: a missing or unknown field falls back to its default instead of discarding the mascot.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? Self.defaultName
        bodyKindName = (try? c.decode(String.self, forKey: .bodyKindName)) ?? Self.defaultBodyKindName
        colorHex = (try? c.decode(String.self, forKey: .colorHex)) ?? Self.defaultColorHex
        eyeStyle = (try? c.decode(MascotEyeStyle.self, forKey: .eyeStyle)) ?? .round
        accessory = (try? c.decode(MascotAccessory.self, forKey: .accessory)) ?? .none
    }
    enum Keys: String, CodingKey { case name, bodyKindName, colorHex, eyeStyle, accessory }

    /// Cleaned value for data read from disk: unusable name, body or color fall back to the defaults.
    func sanitized() -> MascotAppearance {
        var m = self
        m.name = PreferenceText.name(name) ?? Self.defaultName
        m.bodyKindName = PreferenceText.blobKindName(bodyKindName) ?? Self.defaultBodyKindName
        m.colorHex = HexColor.normalize(colorHex) ?? Self.defaultColorHex
        return m
    }
}

/// Built-in palettes. `automatic` keeps the pre-personalization behavior (djb2 tint per session).
public enum ThemePalette: String, Codable, Sendable, CaseIterable {
    case automatic, pastel, neon, mono

    /// Default color for an agent type, nil for `automatic` (=> djb2 tint of the session).
    public func defaultColorHex(for kind: AgentKind) -> String? {
        switch self {
        case .automatic: return nil
        case .pastel:
            switch kind {
            case .claudeCode: return "#F4B99A"
            case .codex: return "#A9C7F5"
            case .genericCLI: return "#B8E0C2"
            case .computerUse: return "#D4BDF0"
            }
        case .neon:
            switch kind {
            case .claudeCode: return "#FF8A3D"
            case .codex: return "#2DE2FF"
            case .genericCLI: return "#6DFF6D"
            case .computerUse: return "#E65CFF"
            }
        case .mono:
            switch kind {
            case .claudeCode: return "#E6E6E6"
            case .codex: return "#BFBFBF"
            case .genericCLI: return "#9A9A9A"
            case .computerUse: return "#D0D0D0"
            }
        }
    }

    /// The five muted tints of `BlobKind.tint(forSession:)` (App/Sources/UI/StatusCircle.swift), as hex.
    static let legacyTints: [String] = [
        HexColor.make(red: 0.45, green: 0.85, blue: 0.70), HexColor.make(red: 0.62, green: 0.60, blue: 1.0),
        HexColor.make(red: 1.0, green: 0.68, blue: 0.55), HexColor.make(red: 0.45, green: 0.75, blue: 1.0),
        HexColor.make(red: 0.80, green: 0.90, blue: 0.45),
    ]

    /// Same hash and index as `BlobKind.tint(forSession:)` so the fallback stays visually identical.
    public static func legacyTintHex(forSession id: String) -> String {
        let h = id.unicodeScalars.reduce(5381 as UInt64) { ($0 &* 33) &+ UInt64($1.value) }
        return legacyTints[Int((h / 7) % UInt64(legacyTints.count))]
    }
}

/// A user-defined bot: name, color, agent type and start prompt/skill. The start prompt is owner input, never agent output.
public struct Bot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var colorHex: String
    /// Name of a UI blob shape ("circle", "cloud", ...), nil => derived from the session id.
    public var blobKindName: String?
    public var agentKind: AgentKind
    public var startPrompt: String
    public var skill: String?
    /// Optional default working folder (absolute local path) preselected by the New session flow. Additive field:
    /// absent in older files.
    public var defaultFolder: String?
    /// Optional default agent-user workspace (folder name) preselected when the session runs as the agent user.
    public var defaultWorkspace: String?
    public let createdAt: Date

    public init(id: String, name: String, colorHex: String, blobKindName: String? = nil, agentKind: AgentKind,
                startPrompt: String, skill: String? = nil, defaultFolder: String? = nil, defaultWorkspace: String? = nil,
                createdAt: Date) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.blobKindName = blobKindName
        self.agentKind = agentKind; self.startPrompt = startPrompt; self.skill = skill
        self.defaultFolder = defaultFolder; self.defaultWorkspace = defaultWorkspace; self.createdAt = createdAt
    }

    // Lenient for the fields added later: a wrong type in `defaultFolder`/`defaultWorkspace` drops just that field, not the bot.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        blobKindName = try? c.decodeIfPresent(String.self, forKey: .blobKindName)
        agentKind = try c.decode(AgentKind.self, forKey: .agentKind)
        startPrompt = try c.decode(String.self, forKey: .startPrompt)
        skill = try? c.decodeIfPresent(String.self, forKey: .skill)
        defaultFolder = try? c.decodeIfPresent(String.self, forKey: .defaultFolder)
        defaultWorkspace = try? c.decodeIfPresent(String.self, forKey: .defaultWorkspace)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
    enum Keys: String, CodingKey { case id, name, colorHex, blobKindName, agentKind, startPrompt, skill, defaultFolder, defaultWorkspace, createdAt }

    /// The first message of a session started with this bot: `/<skill> <start prompt>` (skill name cleaned to
    /// `[A-Za-z0-9:_-]`), just the prompt without a skill, just `/<skill>` without a prompt, nil if both are empty.
    /// Start prompt and skill are owner input from the preferences file, never agent output.
    public var initialMessage: String? {
        let prompt = PreferenceText.startPrompt(startPrompt)
        guard let command = PreferenceText.skillCommandName(skill) else { return prompt }
        return prompt.map { "/\(command) " + $0 } ?? "/\(command)"
    }
}

/// Which level of the precedence chain produced the color.
public enum AppearanceSource: Sendable, Equatable {
    case session, bot, agentDefault, theme, legacyTint
}

public struct ResolvedAppearance: Sendable, Equatable {
    /// Name to show. Falls back to the (app-known) project name, never agent text.
    public let displayName: String
    public let colorHex: String
    public let colorSource: AppearanceSource
    public let blobKindName: String?
    public let botID: String?
}

public enum PreferencesError: Error, Equatable {
    case invalidColor, invalidName, invalidSessionID, notFound, limitReached, invalidFolder, invalidWorkspace
}
