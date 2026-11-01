import AppKit
import AgentBarCore

/// Circle sits at the notch (as a black extension of it) and expands into a panel hanging from the top edge.
@MainActor
final class NotchIslandPresentation<S: SessionStoreReading & ResponseSink>: BarPresentation {
    let identifier = "notch"
    private let controller: PanelController<S>
    init(store: S, startExpanded: Bool = false) {
        controller = PanelController(store: store, style: .notch, startExpanded: startExpanded)
    }
    func present() { controller.present() }
    func dismiss() { controller.dismiss() }
}

/// Floating pill at the top center (Macs without a notch).
@MainActor
final class FloatingPillPresentation<S: SessionStoreReading & ResponseSink>: BarPresentation {
    let identifier = "pill"
    private let controller: PanelController<S>
    init(store: S, startExpanded: Bool = false) {
        controller = PanelController(store: store, style: .pill, startExpanded: startExpanded)
    }
    func present() { controller.present() }
    func dismiss() { controller.dismiss() }
}

/// Free-floating circle at the screen edge; drag to move, position is remembered.
@MainActor
final class DraggableCirclePresentation<S: SessionStoreReading & ResponseSink>: BarPresentation {
    let identifier = "circle"
    private let controller: PanelController<S>
    init(store: S, startExpanded: Bool = false) {
        controller = PanelController(store: store, style: .circle, startExpanded: startExpanded)
    }
    func present() { controller.present() }
    func dismiss() { controller.dismiss() }
}
