import SwiftUI
import AppKit
import AgentBarCore

/// Shared owner-side preferences: one `PreferencesStore` for the whole app (created in `AppEnvironment`) plus a
/// revision counter SwiftUI observes. The store itself is thread safe; its change callback hops to the main actor here.
@MainActor
final class PreferencesHub: ObservableObject {
    static let shared = PreferencesHub(store: PreferencesStore(fileURL: LaunchOptions.current.prefsFile ?? PreferencesStore.defaultFileURL()))

    let store: PreferencesStore
    /// Bumped after every store change; views that read the store observe the hub and re-render.
    @Published private(set) var revision = 0
    private var observerID: UUID?

    init(store: PreferencesStore) {
        self.store = store
        observerID = store.addChangeObserver { [weak self] in
            Task { @MainActor in self?.revision &+= 1 }
        }
    }

    deinit { if let observerID { store.removeChangeObserver(observerID) } }
}

// MARK: color and text helpers

extension Color {
    /// nil for an invalid hex.
    init?(hex: String) {
        guard let c = HexColor.components(hex) else { return nil }
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }

    /// "#RRGGBB" in sRGB (alpha is dropped).
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.gray.usingColorSpace(.sRGB)!
        return HexColor.make(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }
}

extension AgentKind {
    var settingsTitle: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .genericCLI: return "Generic CLI"
        case .computerUse: return "Computer Use"
        }
    }
}

extension ThemePalette {
    var settingsTitle: String {
        switch self {
        case .automatic: return "Automatic"
        case .pastel: return "Pastel"
        case .neon: return "Neon"
        case .mono: return "Mono"
        }
    }

    var settingsSubtitle: String {
        switch self {
        case .automatic: return "A calm tint per session"
        case .pastel: return "Soft colors per agent type"
        case .neon: return "Bright colors per agent type"
        case .mono: return "Shades of gray"
        }
    }
}

extension BlobKind {
    /// Name stored in `Bot.blobKindName` (ASCII identifier, validated by the core).
    var storageName: String {
        switch self {
        case .circle: return "circle"
        case .roundedSquare: return "roundedSquare"
        case .cloud: return "cloud"
        case .drop: return "drop"
        case .triangle: return "triangle"
        }
    }

    var settingsTitle: String {
        switch self {
        case .circle: return "Circle"
        case .roundedSquare: return "Rounded square"
        case .cloud: return "Cloud"
        case .drop: return "Drop"
        case .triangle: return "Triangle"
        }
    }

    init?(storageName: String?) {
        guard let storageName, let k = BlobKind.allCases.first(where: { $0.storageName == storageName }) else { return nil }
        self = k
    }
}

extension PreferencesError {
    var settingsMessage: String {
        switch self {
        case .invalidColor: return "That color is not valid. Pick a color or enter it as #RRGGBB."
        case .invalidName: return "The name is empty or contains only unusable characters."
        case .invalidSessionID: return "The session id is not valid."
        case .notFound: return "This bot no longer exists."
        case .limitReached: return "The limit of \(PreferencesStore.maxBots) bots is reached. Delete a bot first."
        case .invalidFolder: return "The default folder must be an absolute path (for example /Users/you/project) without \"..\"."
        case .invalidWorkspace: return "Workspace names may use letters, digits, dot, dash and underscore (max 64, no leading dot)."
        }
    }
}
