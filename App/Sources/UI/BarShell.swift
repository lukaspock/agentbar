import SwiftUI
import AgentBarCore

/// Root view of the panel window: one black shape that is a circle/capsule when collapsed and the detail panel when expanded.
struct BarShell<S: SessionStoreReading & ResponseSink>: View {
    @ObservedObject var store: S
    @ObservedObject var model: BarViewModel
    @State private var contentHeight: CGFloat = 160
    @State private var emptyHeight: CGFloat = 120
    @ObservedObject private var prefs = PreferencesHub.shared
    @ObservedObject private var router = PanelRouter.shared
    /// Start of the mascot's current "rest": when it appeared or when the pointer last visited it (it sleeps after a while).
    @State private var mascotSince = Date()

    var body: some View {
        let l = model.layout
        let expanded = model.expanded
        let empty = store.sessions.isEmpty     // no agent: the owner's mascot takes the place of the status circle
        // An inline page (New session, Agent user) needs the full detail panel, also without any agent.
        let showsDetail = !empty || router.page != nil
        let _ = prefs.revision
        let mascot = prefs.store.mascot()
        let mascotSize = min(l.dotSize * 1.2, l.collapsedSize.height - 4)
        let shownHeight = showsDetail ? contentHeight : emptyHeight
        let w = expanded ? (showsDetail ? l.expandedWidth : l.emptyExpandedWidth) : l.collapsedSize.width
        let tint = SessionLook.aggregateTint(sessions: store.sessions, state: store.aggregateState, store: prefs.store)
        let h = expanded ? min(max(shownHeight, l.collapsedSize.height), l.maxHeight) : l.collapsedSize.height
        let shape = UnevenRoundedRectangle(cornerRadii: expanded ? l.expandedRadii : l.collapsedRadii, style: .continuous)

        ZStack(alignment: .top) {
            DetailPanel(store: store, model: model, contentHeight: $contentHeight)
                .opacity(expanded && showsDetail ? 1 : 0)
                .allowsHitTesting(expanded && showsDetail)
                .environment(\.barActive, expanded && showsDetail)
            MascotEmptyPanel(appearance: mascot, since: mascotSince, topPadding: l.expandedTopPadding,
                             width: l.emptyExpandedWidth) { emptyHeight = $0 }
                .opacity(expanded && !showsDetail ? 1 : 0)
                .allowsHitTesting(expanded && !showsDetail)
                .environment(\.barActive, expanded && !showsDetail)
            StatusCircle(state: store.aggregateState, size: l.dotSize, tint: tint)
                .frame(width: l.collapsedSize.width, height: l.collapsedSize.height, alignment: l.dotAlignment)
                .padding(.trailing, l.dotAlignment == .trailing ? l.dotTrailingPadding : 0)
                .opacity(expanded || empty ? 0 : 1)
                .allowsHitTesting(false)
                .environment(\.barActive, !expanded && !empty)
            MascotView(appearance: mascot, size: mascotSize, since: mascotSince)
                .frame(width: l.collapsedSize.width, height: l.collapsedSize.height, alignment: l.dotAlignment)
                .padding(.trailing, l.dotAlignment == .trailing ? l.dotTrailingPadding : 0)
                .scaleEffect(empty ? 1 : 0.6)
                .opacity(expanded || !empty ? 0 : 1)
                .allowsHitTesting(false)
                .environment(\.barActive, !expanded && empty)
        }
        .frame(width: w, height: h, alignment: .top)
        .background(Color.black)
        .clipShape(shape)
        .gesture(l.draggable ? DragGesture(minimumDistance: 4)
            .onChanged { _ in model.onDrag?(.changed) }
            .onEnded { _ in model.onDrag?(.ended) } : nil)
        .offset(x: model.offsetX)
        .padding(.top, l.windowTopInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "root")
        .onAppear { model.showsEmptyState = !showsDetail; model.contentHeight = shownHeight; pageChanged(router.page) }
        .onChange(of: shownHeight) { _, new in model.contentHeight = new }
        .onChange(of: router.page) { _, page in pageChanged(page) }
        .onChange(of: expanded) { _, now in
            // The Agent user card is a glance, not a task: it closes with the panel. The New session flow keeps the panel open.
            if !now, router.page == .agentUser { router.close() }
        }
        .onChange(of: showsDetail) { _, new in model.showsEmptyState = !new }
        .onChange(of: empty) { _, new in
            if new { mascotSince = Date() }   // back after the last agent left: awake, with a little hop if it had been asleep
        }
        .onChange(of: expanded) { _, new in if !new && empty { mascotSince = Date() } }
        .animation(BarTheme.spring, value: model.expanded)
        .animation(BarTheme.spring, value: model.offsetX)
        .animation(BarTheme.spring, value: shownHeight)
        .animation(BarTheme.spring, value: empty)
        .animation(BarTheme.spring, value: showsDetail)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    /// A page opened (menu or button): the panel opens too; the New session flow also keeps it open and key.
    private func pageChanged(_ page: PanelRouter.Page?) {
        switch page {
        case .newSession: model.setFlowActive(true)
        case .agentUser: model.setFlowActive(false); model.autoExpand(hold: 10)
        case nil: model.setFlowActive(false)
        }
    }
}
