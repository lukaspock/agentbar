import Foundation

/// Adapters keyed by the name used in the transport's `payload` op.
public enum AdapterRegistry {
    public static func make() -> [String: AgentAdapter] {
        ["claudeCode": ClaudeCodeAdapter(), "genericCLI": GenericCLIAdapter(),
         CodexAdapter.adapterId: CodexAdapter()]
    }
}
