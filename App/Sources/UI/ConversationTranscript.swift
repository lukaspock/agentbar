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
    @State private var listHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(history) { e in line(e).id(e.id).help(e.date.formatted(date: .omitted, time: .standard)) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.trailing, 6)
                .background(GeometryReader { Color.clear.preference(key: TranscriptHeightKey.self, value: $0.size.height) })
            }
            .onPreferenceChange(TranscriptHeightKey.self) { listHeight = $0 }
            .frame(height: listHeight == 0 ? maxHeight : min(listHeight, maxHeight))
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: history.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func line(_ e: HistoryEntry) -> some View {
        switch ChatLine.parse(e) {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                bubble(text, fg: .black, bg: Color.white.opacity(0.92))
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

    private func bubble(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(fg)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg))
    }
}
