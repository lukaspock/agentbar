import SwiftUI
import AgentBarCore

/// Root view of the panel window: one black shape that is a circle/capsule when collapsed and the detail panel when expanded.
struct BarShell<S: SessionStoreReading & ResponseSink>: View {
    @ObservedObject var store: S
    @ObservedObject var model: BarViewModel
    @State private var contentHeight: CGFloat = 160

    var body: some View {
        let l = model.layout
        let expanded = model.expanded
        let w = expanded ? l.expandedWidth : l.collapsedSize.width
        let h = expanded ? min(max(contentHeight, l.collapsedSize.height), l.maxHeight) : l.collapsedSize.height
        let shape = UnevenRoundedRectangle(cornerRadii: expanded ? l.expandedRadii : l.collapsedRadii, style: .continuous)

        ZStack(alignment: .top) {
            DetailPanel(store: store, model: model, contentHeight: $contentHeight)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
            StatusCircle(state: store.aggregateState, size: l.dotSize)
                .frame(width: l.collapsedSize.width, height: l.collapsedSize.height, alignment: l.dotAlignment)
                .padding(.trailing, l.dotAlignment == .trailing ? l.dotTrailingPadding : 0)
                .opacity(expanded ? 0 : 1)
                .allowsHitTesting(false)
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
        .onChange(of: contentHeight) { _, new in model.contentHeight = new }
        .animation(BarTheme.spring, value: model.expanded)
        .animation(BarTheme.spring, value: model.offsetX)
        .animation(BarTheme.spring, value: contentHeight)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
