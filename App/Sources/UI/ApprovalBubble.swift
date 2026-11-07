import SwiftUI
import AgentBarCore

/// Everything a conversation panel needs to show the open request of its session as a bubble. Built by `DetailPanel`
/// (which owns the click guard); the bubble itself never talks to the store directly.
struct BubbleRequest {
    let request: AgentRequest
    let extra: Int
    let armed: Bool                          // false while the bubble just appeared/moved or the panel is animating
    let canAnswer: () -> Bool                // live check at click time (still pending, same placement, settled)
    let respond: (AgentResponse) -> Void     // always for THIS request's id
}

/// The open request of the selected session as the last message of its conversation (agent side, highlighted).
/// Same safety rules as `RequestCard`: buttons are armed only after the settle window, every answer re-checks the live
/// state, and the answer always carries this bubble's own request id. No keyboard shortcuts on purpose.
struct ApprovalBubble: View {
    let bubble: BubbleRequest
    @ObservedObject var model: BarViewModel
    @State private var reason = ""

    private var request: AgentRequest { bubble.request }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if bubble.extra > 0 {
                    Text("+\(bubble.extra) more waiting").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                }
                if request.type == .approval {
                    ApprovalBody(text: request.text)      // the complete text, scrollable
                } else {
                    Text(request.text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.95))
                        .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                }
                actions
                timeoutLine
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BarTheme.needsInput.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(BarTheme.needsInput.opacity(0.55), lineWidth: 1))
            Spacer(minLength: 12)
        }
        // Screenshots only: "--demo-bubble-answer deny:wrong folder" presses the button as soon as the bubble is armed
        // (goes through the same guarded `answer`).
        .onChange(of: bubble.armed) { _, armed in if armed { demoAnswer() } }
    }

    private func demoAnswer() {
        guard let spec = LaunchOptions.current.demoBubbleAnswer else { return }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        if parts[0] == "deny" { reason = parts.count > 1 ? parts[1] : ""; deny() } else { answer(parts[0]) }
    }

    /// Re-checks the live state, then answers with this bubble's request id.
    private func answer(_ optionId: String?, text: String? = nil) {
        guard bubble.armed, bubble.canAnswer() else { return }
        bubble.respond(AgentResponse(requestId: request.requestId, optionId: optionId, text: text))
    }

    private func deny() {
        let t = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        answer("deny", text: t.isEmpty ? nil : t)
    }

    @ViewBuilder private var actions: some View {
        switch request.type {
        case .approval: approvalActions
        case .question:
            if !request.options.isEmpty {
                HStack(spacing: 8) { ForEach(request.options) { o in PillButton(title: o.label, style: o.style, enabled: bubble.armed) { answer(o.id) } } }
            }
            ReplyField(placeholder: "Reply and press Enter", onEditing: { model.setEditing($0) }, onSubmit: { answer(nil, text: $0) })
                .frame(height: 20)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.10)))
                .opacity(bubble.armed ? 1 : 0.4)
        case .info:
            HStack(spacing: 8) {
                ForEach(request.options) { o in PillButton(title: o.label, style: o.style, enabled: bubble.armed) { answer(o.id) } }
                if request.options.isEmpty { PillButton(title: "OK", style: .primary, enabled: bubble.armed) { answer(nil) } }
            }
        }
    }

    private var allow: RequestOption? { request.options.first { $0.id == "allow" } }
    private var always: RequestOption? { request.options.first { $0.id == "always" } }
    private var denyOption: RequestOption? { request.options.first { $0.id == "deny" } }
    /// Options of an adapter that does not use the allow/deny/always ids: shown as they are, no reason field.
    private var hasKnownIds: Bool { request.options.isEmpty || allow != nil || always != nil || denyOption != nil }

    @ViewBuilder private var approvalActions: some View {
        if hasKnownIds {
            let hasAllow = request.options.isEmpty || allow != nil
            let hasDeny = request.options.isEmpty || denyOption != nil
            HStack(spacing: 8) {
                if hasAllow { PillButton(title: "Allow", style: .primary, enabled: bubble.armed) { answer("allow") } }
                if always != nil || request.options.isEmpty { PillButton(title: "Always", enabled: bubble.armed) { answer("always") } }
                if hasDeny { PillButton(title: "Deny", style: .destructive, enabled: bubble.armed) { deny() } }
                ForEach(request.options.filter { !["allow", "deny", "always"].contains($0.id) }) { o in
                    PillButton(title: o.label, style: o.style, enabled: bubble.armed) { answer(o.id) }
                }
            }
            if let detail = always?.detail {
                // Where the "Always" rule would apply, as far as the agent's data tells.
                (Text("Always: ").fontWeight(.semibold) + Text(detail))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasDeny {
                InlineTextField(text: $reason, placeholder: "Reason for denying (optional)", limit: 200,
                                onEditing: { model.setEditing($0) }, onSubmit: { deny() })
                    .frame(height: 20)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
                    .opacity(bubble.armed ? 1 : 0.5)
            }
        } else {
            HStack(spacing: 8) { ForEach(request.options) { o in PillButton(title: o.label, style: o.style, enabled: bubble.armed) { answer(o.id) } } }
        }
    }

    /// Only shown when the request has a real app-side timeout (see `RequestTimeout.note` for the exact wording).
    @ViewBuilder private var timeoutLine: some View {
        if request.timeoutSeconds != nil {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                if let note = RequestTimeout.note(request, now: ctx.date) {
                    Text(note).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}
