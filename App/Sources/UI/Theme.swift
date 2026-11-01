import SwiftUI
import AgentBarCore

enum BarTheme {
    static let needsInput = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let error = Color(red: 1.0, green: 0.30, blue: 0.36)
    static let idle = Color.white.opacity(0.40)
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.86)

    static func color(for state: SessionState) -> Color {
        switch state {
        case .needsInput: return needsInput
        case .error: return error
        case .working: return Color.white.opacity(0.9)
        case .idle, .done: return idle
        }
    }

    static func label(for state: SessionState) -> String {
        switch state {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs input"
        case .error: return "Error"
        case .done: return "Done"
        }
    }

    static func icon(for kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: return "terminal"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .genericCLI: return "apple.terminal"
        case .computerUse: return "cursorarrow.click.2"
        }
    }
}
