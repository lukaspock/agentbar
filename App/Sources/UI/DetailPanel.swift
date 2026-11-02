import SwiftUI
import AgentBarCore

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Feeds the pure `ApprovalClickGuard` from the view layer and re-renders once the settle window is over.
@MainActor
final class ApprovalGuardModel: ObservableObject {
    @Published private(set) var epoch = 0
    private var state = ApprovalClickGuard()

    func observe(order: [String]) { state.observe(order: order, now: Date()); scheduleRefresh() }
    /// Height animation of the panel takes longer than the card settle window: extend it a little.
    func layoutChanged() { state.layoutChanged(now: Date().addingTimeInterval(0.2)); scheduleRefresh() }
    func isArmed(_ id: String, currentOrder: [String]) -> Bool {
        state.isArmed(id, currentOrder: currentOrder, now: Date())
    }
    private func scheduleRefresh() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((ApprovalClickGuard.settleInterval + 0.25) * 1_000_000_000))
            self?.epoch += 1
        }
    }
}

struct DetailPanel<S: SessionStoreReading & ResponseSink>: View {
    @ObservedObject var store: S
    @ObservedObject var model: BarViewModel
    @Binding var contentHeight: CGFloat
    @StateObject private var guardModel = ApprovalGuardModel()

    /// One card per session (its oldest request), ordered oldest request first; independent of session state.
    private var openRequests: [(sessionId: String, request: AgentRequest)] {
        RequestOrdering.stable(store.sessions.compactMap { s in s.pendingRequests.first.map { (s.id, $0) } })
    }

    private var selected: AgentSession? {
        store.sessions.first { $0.id == model.selectedSessionId } ?? store.sessions.first
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
        }
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        .onAppear { guardModel.observe(order: openRequests.map(\.request.requestId)); guardModel.layoutChanged() }
        .onChange(of: openRequests.map(\.request.requestId)) { _, ids in guardModel.observe(order: ids) }
        .onChange(of: contentHeight) { _, _ in guardModel.layoutChanged() }
        .onChange(of: model.expanded) { _, _ in guardModel.layoutChanged() }
        .frame(width: model.layout.expandedWidth)
    }

    /// Click-time check, evaluated against the live store, not against what was rendered.
    private func canAnswer(requestId: String, sessionId: String) -> Bool {
        guard store.sessions.first(where: { $0.id == sessionId })?.pendingRequests.contains(where: { $0.requestId == requestId }) == true
        else { return false }
        return guardModel.isArmed(requestId, currentOrder: openRequests.map(\.request.requestId))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if store.sessions.isEmpty {
                Text("No agents connected").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }
            let open = openRequests
            let order = open.map(\.request.requestId)
            let _ = guardModel.epoch   // re-render when a settle window ends
            ForEach(open, id: \.request.requestId) { item in
                if let session = store.sessions.first(where: { $0.id == item.sessionId }) {
                    RequestCard(session: session, request: item.request, extra: session.pendingRequests.count - 1,
                                armed: guardModel.isArmed(item.request.requestId, currentOrder: order),
                                canAnswer: { canAnswer(requestId: item.request.requestId, sessionId: item.sessionId) },
                                sink: store, model: model)
                }
            }
            if !store.sessions.isEmpty {
                VStack(spacing: 2) {
                    ForEach(store.sessions) { session in
                        SessionRow(session: session, selected: session.id == selected?.id, sink: store)
                            .onTapGesture { model.selectedSessionId = session.id }
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
                .animation(BarTheme.spring, value: store.sessions.map(\.id))
                if store.sessions.contains(where: { removableQuietly($0) }) {
                    Button {
                        withAnimation(BarTheme.spring) {
                            for s in store.sessions where removableQuietly(s) { store.remove(sessionId: s.id) }
                        }
                    } label: {
                        Text("Erledigte entfernen").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                            .padding(.vertical, 2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 10)
                    .transition(.opacity)
                }
            }
            if let selected, !selected.history.isEmpty { HistoryList(session: selected) }
        }
        .padding(.top, model.layout.expandedTopPadding)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(width: model.layout.expandedWidth, alignment: .leading)
    }

    /// done/idle sessions without pending requests: safe to remove without any confirmation.
    private func removableQuietly(_ s: AgentSession) -> Bool {
        (s.state == .done || s.state == .idle) && s.pendingRequests.isEmpty
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusCircle(state: store.aggregateState, size: 16)
            Text(BarTheme.label(for: store.aggregateState))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Text("\(store.sessions.count) \(store.sessions.count == 1 ? "agent" : "agents")")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

// MARK: - Requests

private struct RequestCard<Sink: ResponseSink>: View {
    let session: AgentSession
    let request: AgentRequest
    let extra: Int
    let armed: Bool                    // false while the card just appeared/moved or the panel is animating
    let canAnswer: () -> Bool          // live check at click time (request still pending, same position, settled)
    let sink: Sink
    @ObservedObject var model: BarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: BarTheme.icon(for: session.kind)).font(.system(size: 11))
                Text(session.name).font(.system(size: 12, weight: .medium))
                if extra > 0 { Text("+\(extra) more waiting").font(.system(size: 11)).opacity(0.7) }
            }
            .foregroundStyle(.white.opacity(0.55))
            if request.type == .approval {
                ApprovalBody(text: request.text)      // the complete text, scrollable
            } else {
                Text(request.text)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.95))
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    /// Always answers THIS card's own request id; ignored when the card is not armed or the request is gone.
    private func answer(_ optionId: String?, text: String? = nil) {
        guard armed, canAnswer() else { return }
        sink.respond(AgentResponse(requestId: request.requestId, optionId: optionId, text: text), sessionId: session.id)
    }

    @ViewBuilder private var actions: some View {
        switch request.type {
        case .approval:
            HStack(spacing: 8) {
                ForEach(approvalButtons, id: \.id) { o in
                    PillButton(title: o.label, style: o.style, enabled: armed) { answer(o.id) }
                }
            }
        case .question:
            if !request.options.isEmpty {
                HStack(spacing: 8) {
                    ForEach(request.options) { o in PillButton(title: o.label, style: o.style, enabled: armed) { answer(o.id) } }
                }
            }
            ReplyField(placeholder: "Reply and press Enter",
                       onEditing: { model.setEditing($0) },
                       onSubmit: { answer(nil, text: $0) })
                .frame(height: 20)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.10)))
                .opacity(armed ? 1 : 0.4)   // Enter is ignored while the card settles: show it
                .animation(.easeOut(duration: 0.15), value: armed)
        case .info:
            HStack(spacing: 8) {
                ForEach(request.options) { o in PillButton(title: o.label, style: o.style, enabled: armed) { answer(o.id) } }
                if request.options.isEmpty { PillButton(title: "OK", style: .primary, enabled: armed) { answer(nil) } }
            }
        }
    }

    /// allow/deny/always map to Yes/No/Always; other options keep their own labels; no options => the three defaults.
    private var approvalButtons: [RequestOption] {
        let known = ["allow": "Yes", "deny": "No", "always": "Always"]
        let present = request.options.filter { known[$0.id] != nil }
        if request.options.isEmpty {
            return [RequestOption(id: "allow", label: "Yes", style: .primary), RequestOption(id: "deny", label: "No"),
                    RequestOption(id: "always", label: "Always")]
        }
        if present.isEmpty { return request.options }
        let mapped = ["allow", "deny", "always"].compactMap { id in
            present.first { $0.id == id }.map {
                RequestOption(id: id, label: known[id]!, style: id == "allow" ? .primary : ($0.style == .destructive ? .destructive : .normal))
            }
        }
        return mapped + request.options.filter { known[$0.id] == nil }
    }
}

private struct BodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Approval text: first line is the headline, the rest (cwd, `key: value` lines) is monospaced and scrollable.
/// Shows the complete text; only the visible window is height-limited.
private struct ApprovalBody: View {
    let text: String
    @State private var bodyHeight: CGFloat = 0
    private let maxHeight: CGFloat = 170

    private var parts: (head: String, rest: String) {
        guard let nl = text.firstIndex(of: "\n") else { return (text, "") }
        return (String(text[..<nl]), String(text[text.index(after: nl)...]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(parts.head).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            if !parts.rest.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(parts.rest)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .background(GeometryReader { Color.clear.preference(key: BodyHeightKey.self, value: $0.size.height) })
                }
                .onPreferenceChange(BodyHeightKey.self) { bodyHeight = $0 }
                .frame(height: bodyHeight == 0 ? maxHeight : min(bodyHeight, maxHeight))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35)))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if bodyHeight > maxHeight {
                    Text("↓ Mehr Text: im Feld scrollen, bevor du antwortest")
                        .font(.system(size: 10)).foregroundStyle(BarTheme.needsInput)
                }
            }
        }
    }
}

struct PillButton: View {
    let title: String
    var style: RequestOption.Style = .normal
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: { if enabled { action() } }) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(fg)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(bg))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .animation(.easeOut(duration: 0.15), value: enabled)
    }

    private var fg: Color { style == .primary ? .black : (style == .destructive ? BarTheme.error : .white) }
    private var bg: Color { style == .primary ? .white : Color.white.opacity(0.14) }
}

// MARK: - Sessions & history

private struct SessionRow<Sink: ResponseSink>: View {
    let session: AgentSession
    let selected: Bool
    let sink: Sink
    @State private var hovering = false
    @State private var confirming = false

    /// Removing a session that is working or has open requests cancels the agent's request => needs a second click.
    private var needsConfirm: Bool { session.state == .working || session.state == .needsInput || !session.pendingRequests.isEmpty }
    private var alwaysVisible: Bool { [.done, .idle, .error].contains(session.state) && session.pendingRequests.isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            BlobView(state: session.state, kind: .forSession(session.id), size: 26,
                     tint: BlobKind.tint(forSession: session.id))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    Image(systemName: BarTheme.icon(for: session.kind))
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                HStack(spacing: 5) {
                    Circle().fill(BarTheme.color(for: session.state)).frame(width: 6, height: 6)
                    Text(BarTheme.label(for: session.state)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                if let action = session.currentAction {
                    Text(action).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if session.supportsStop {
                Button { sink.stop(sessionId: session.id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text("Stop").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(BarTheme.error)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(BarTheme.error.opacity(0.18)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if hovering || alwaysVisible || confirming { removeButton.transition(.opacity) }
        }
        .onHover { hovering = $0 }
        .animation(BarTheme.spring, value: hovering)
        .animation(BarTheme.spring, value: confirming)
        .task(id: confirming) {
            guard confirming else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { confirming = false }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.07 : 0)))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var removeButton: some View {
        Button {
            if needsConfirm && !confirming { confirming = true; return }
            withAnimation(BarTheme.spring) { sink.remove(sessionId: session.id) }
        } label: {
            Group {
                if confirming {
                    Text("Wirklich?").font(.system(size: 11, weight: .semibold)).foregroundStyle(BarTheme.error)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(BarTheme.error.opacity(0.18)))
                } else {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(hovering ? 0.55 : 0.28))
                        .frame(width: 20, height: 20)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Entfernen")
    }
}

private struct HistoryList: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent · \(session.name)").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            ForEach(session.history.suffix(5)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.date, format: .dateTime.hour().minute())
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.35))
                    Text(e.text).font(.system(size: 12))
                        .foregroundStyle(e.kind == .error ? BarTheme.error : .white.opacity(0.7)).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
    }
}
