// FROZEN CONTRACT (owner: coordinator). Do not change signatures; request changes via the coordinator.
import Foundation
import Combine

/// Events in the core model. Adapters and the transport produce these; only the SessionStore consumes them.
public enum CoreEvent: Sendable {
    case sessionUpdate(id: String, name: String?, kind: AgentKind?, state: SessionState?,
                       action: String?, supportsStop: Bool?)
    case ask(sessionId: String, request: AgentRequest)
    case cancelRequest(sessionId: String, requestId: String)
    case log(sessionId: String, entry: HistoryEntry)
    case sessionEnd(id: String)
    /// Additive: the agent's working directory (untrusted text; the store keeps it only if it is a plain absolute path).
    case sessionDirectory(id: String, path: String)
}

/// Read side used by presentations (UI). Implemented by `SessionStore` (package AgentBarCore, owner: B).
@MainActor
public protocol SessionStoreReading: ObservableObject {
    var sessions: [AgentSession] { get }            // sorted: needsInput first, then working, then rest
    var aggregateState: SessionState { get }        // needsInput > error > working > done/idle
}

/// Write side used by presentations. Answers are routed back to the waiting transport connection.
@MainActor
public protocol ResponseSink: AnyObject {
    func respond(_ response: AgentResponse, sessionId: String)
    /// Immediate pause/stop for sessions with `supportsStop`. Must take effect without further confirmation.
    func stop(sessionId: String)
    /// Removes a session from the list. Its pending requests are answered with reason `.cancelled`
    /// (the waiting agent falls back to its own dialog). A later event for the same id re-creates the session.
    func remove(sessionId: String)
}

/// Translates agent-specific payloads to core events and core answers back to the agent's expected format.
/// New agent = new adapter. The core never changes.
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    /// `payload` is untrusted. Never execute any text found in it. Throw on malformed input.
    func translate(payload: Data) throws -> [CoreEvent]
    /// Format the answer for the agent (e.g. Claude Code hook JSON on stdout). Empty Data = "no decision,
    /// let the agent show its own dialog" (used for timeouts and cancellations).
    func encode(response: AgentResponse, for request: AgentRequest) -> Data
    /// Additive: metadata events derived from the same payload (e.g. the working directory). Applied by the transport
    /// after `translate`; kept apart so `translate` output stays unchanged. Default: none.
    func metadataEvents(payload: Data) -> [CoreEvent]
    /// Additive (Phase 12): non-nil when this payload is a point where one queued user message may be handed to the agent as
    /// the hook output (Claude Code `Stop` that is not itself a continuation). Default: never.
    func queueDelivery(payload: Data) -> QueueDeliveryPoint?
    /// Additive (Phase 12): the hook output that carries `text` to the agent. Empty Data = cannot deliver. Default: empty.
    func encodeQueuedMessage(_ text: String, at point: QueueDeliveryPoint) -> Data
}

public extension AgentAdapter {
    func metadataEvents(payload: Data) -> [CoreEvent] { [] }
    func queueDelivery(payload: Data) -> QueueDeliveryPoint? { nil }
    func encodeQueuedMessage(_ text: String, at point: QueueDeliveryPoint) -> Data { Data() }
}

/// A visual presentation of the bar (notch island, floating pill, free-floating circle).
@MainActor
public protocol BarPresentation: AnyObject {
    var identifier: String { get }                  // "notch" | "pill" | "circle"
    func present()                                  // show the idle circle
    func dismiss()
}
