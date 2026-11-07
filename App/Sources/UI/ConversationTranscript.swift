import SwiftUI
import AgentBarCore

private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Chat-style transcript (oldest first, follows the end) shared by chat sessions and hook-only sessions.
/// User = light bubble right, agent = dim bubble left, errors = red bubble, everything else = small notes.
/// The time of an entry is available as tooltip.
struct ConversationTranscript: View {
    let history: [HistoryEntry]
    let maxHeight: CGFloat
    /// Messages waiting for Claude's next step (hook sessions): shown last, dimmed, with a cancel button.
    var queued: [QueuedMessage] = []
    var onCancelQueued: ((UUID) -> Void)?
    @State private var listHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(history) { e in line(e).id(e.id).help(e.date.formatted(date: .omitted, time: .standard)) }
                    ForEach(queued) { q in queuedLine(q).id(q.id).help("Queued " + q.date.formatted(date: .omitted, time: .standard)) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.trailing, 6)
                .background(GeometryReader { Color.clear.preference(key: TranscriptHeightKey.self, value: $0.size.height) })
            }
            .onPreferenceChange(TranscriptHeightKey.self) { listHeight = $0 }
            .frame(height: listHeight == 0 ? maxHeight : min(listHeight, maxHeight))
            .onAppear {
                proxy.scrollTo("end", anchor: .bottom)
                // again once the height has settled (bubbles and captions below the first screenful)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: history.count + queued.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func line(_ e: HistoryEntry) -> some View {
        switch ChatLine.parse(e) {
        case .user(let text):
            if e.kind == .answer, e.text.hasPrefix(MessageQueueLimits.deliveredPrefix) {
                // A queued message that reached Claude (Stop hook): same bubble, marked as delivered.
                VStack(alignment: .trailing, spacing: 2) {
                    HStack {
                        Spacer(minLength: 40)
                        bubble(text, fg: .black, bg: Color.white.opacity(0.92))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                        Text("delivered").font(.system(size: 9))
                    }
                    .foregroundStyle(.white.opacity(0.4)).padding(.trailing, 4)
                }
            } else {
                HStack {
                    Spacer(minLength: 40)
                    bubble(text, fg: .black, bg: Color.white.opacity(0.92))
                }
            }
        case .agent(let text):
            HStack {
                bubble(text, fg: .white, bg: Color.white.opacity(0.28))
                Spacer(minLength: 40)
            }
        case .error(let text):
            HStack {
                bubble(text, fg: .white, bg: BarTheme.error.opacity(0.55))
                Spacer(minLength: 40)
            }
        case .note(let text):
            Text(text).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                .lineLimit(2).padding(.horizontal, 4)
        }
    }

    /// Waiting message: dimmed bubble, clock + "waiting for Claude's next step", x cancels it while it is still queued.
    private func queuedLine(_ q: QueuedMessage) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack {
                Spacer(minLength: 40)
                bubble(q.text, fg: .black.opacity(0.7), bg: Color.white.opacity(0.5))
            }
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 8, weight: .semibold))
                Text("queued · waiting for Claude's next step").font(.system(size: 9))
                if let onCancelQueued {
                    Button { onCancelQueued(q.id) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                            .padding(2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove this message from the queue")
                    .accessibilityLabel("Cancel queued message")
                }
            }
            .foregroundStyle(.white.opacity(0.5)).padding(.trailing, 2)
        }
    }

    private func bubble(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(fg)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg))
    }
}
