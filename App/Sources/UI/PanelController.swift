import AppKit
import SwiftUI
import Combine
import AgentBarCore

/// Borderless transparent panel above the menu bar. Never activates the app; key only while a reply field is being edited.
final class BarPanel: NSPanel {
    var allowKey = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class BarHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosts the SwiftUI shell in a panel, places it per presentation style and polls the pointer so that only the visible shape
/// receives mouse events (the rest of the window ignores them and lets clicks through).
@MainActor
final class PanelController<S: SessionStoreReading & ResponseSink> {
    private static var anchorKey: String { "circleAnchor" }
    let style: PresentationStyle
    private let store: S
    private let model: BarViewModel
    private let panel = BarPanel()
    private static var debugHover: Bool { ProcessInfo.processInfo.environment["AGENTBAR_DEBUG_HOVER"] == "1" }
    private var tickCount = 0
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var anchor = CGPoint.zero            // circle style: top-center of the circle, screen coordinates
    private var dragOrigin: (anchor: CGPoint, mouse: CGPoint)?

    init(store: S, style: PresentationStyle, startExpanded: Bool) {
        self.store = store
        self.style = style
        let notch = NotchMetrics.current()
        let screen = style == .notch ? notch.screen : (NSScreen.main ?? NSScreen.screens[0])
        model = BarViewModel(layout: BarLayout.make(style: style, notch: notch, screen: screen), startExpanded: startExpanded)
        if style == .circle { anchor = Self.loadAnchor() }

        panel.contentView = BarHostingView(rootView: BarShell(store: store, model: model))
        model.keyHandler = { [weak self] editing in if !editing { self?.releaseKey() } }
        model.onDrag = { [weak self] phase in self?.handleDrag(phase) }
        model.$expanded.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateOffset() }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: .agentBarAutoExpand)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.model.autoExpand() } }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }.store(in: &bag)
    }

    func present() {
        reposition()
        panel.orderFrontRegardless()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        panel.orderOut(nil)
    }

    // MARK: Pointer

    /// Target visible shape in screen coordinates, derived from layout state (not from SwiftUI geometry callbacks).
    private func visibleScreenRect() -> CGRect? {
        let l = model.layout
        let w = model.expanded ? l.expandedWidth : l.collapsedSize.width
        let h = model.expanded ? min(max(model.contentHeight, l.collapsedSize.height), l.maxHeight) : l.collapsedSize.height
        let win = panel.frame
        guard win.width > 0 else { return nil }
        let cx = win.midX + model.offsetX
        return CGRect(x: cx - w / 2, y: win.maxY - l.windowTopInset - h, width: w, height: h)
    }

    private func tick() {
        guard let rect = visibleScreenRect() else {
            if Self.debugHover { tickCount += 1; if tickCount % 30 == 0 { NSLog("[hover] no panel frame") } }
            return
        }
        let inside = rect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if Self.debugHover {
            tickCount += 1
            if tickCount % 15 == 0 {
                NSLog("[hover] panel=%@ visibleFrame=n/a%@ rect=%@ mouse=%@ inside=%d expanded=%d",
                      NSStringFromRect(panel.frame), "", NSStringFromRect(rect),
                      NSStringFromPoint(NSEvent.mouseLocation), inside ? 1 : 0, model.expanded ? 1 : 0)
            }
        }
        let wantsMouse = inside || model.isEditing || dragOrigin != nil
        if panel.ignoresMouseEvents == wantsMouse { panel.ignoresMouseEvents = !wantsMouse }
        model.pointerChanged(inside || dragOrigin != nil)
    }

    private func releaseKey() {
        panel.allowKey = false
        panel.makeFirstResponder(nil)
        if panel.isKeyWindow { panel.orderOut(nil); panel.orderFrontRegardless() }
    }

    // MARK: Placement

    private func targetScreen() -> NSScreen {
        switch style {
        case .notch: return NotchMetrics.current().screen
        case .pill: return NSScreen.main ?? NSScreen.screens[0]
        case .circle:
            return NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        }
    }

    func reposition() {
        let notch = NotchMetrics.current()
        let screen = targetScreen()
        model.layout = BarLayout.make(style: style, notch: notch, screen: screen)
        let size = BarLayout.windowSize
        let centerX: CGFloat, top: CGFloat
        switch style {
        case .notch: centerX = notch.centerX; top = screen.frame.maxY
        case .pill: centerX = screen.frame.midX; top = screen.frame.maxY
        case .circle:
            anchor = clamp(anchor, to: screen)
            centerX = anchor.x; top = anchor.y
        }
        panel.setFrame(NSRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                       display: true)
        updateOffset()
    }

    /// Keeps the expanded panel of the draggable circle on screen.
    private func updateOffset() {
        guard style == .circle else { return }
        let screen = targetScreen().frame
        let half = model.layout.expandedWidth / 2
        let desired = min(max(anchor.x, screen.minX + 8 + half), screen.maxX - 8 - half)
        model.offsetX = model.expanded ? desired - anchor.x : 0
    }

    private func clamp(_ p: CGPoint, to screen: NSScreen) -> CGPoint {
        let f = screen.frame
        return CGPoint(x: min(max(p.x, f.minX + 16), f.maxX - 16), y: min(max(p.y, f.minY + 40), f.maxY))
    }

    // MARK: Dragging (circle)

    private func handleDrag(_ phase: DragPhase) {
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            if dragOrigin == nil { dragOrigin = (anchor, mouse) }
            guard let o = dragOrigin else { return }
            anchor = clamp(CGPoint(x: o.anchor.x + mouse.x - o.mouse.x, y: o.anchor.y + mouse.y - o.mouse.y), to: targetScreen())
            let size = BarLayout.windowSize
            panel.setFrameOrigin(CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height))
            updateOffset()
        case .ended:
            dragOrigin = nil
            UserDefaults.standard.set(NSStringFromPoint(anchor), forKey: Self.anchorKey)
        }
    }

    private static func loadAnchor() -> CGPoint {
        if let s = UserDefaults.standard.string(forKey: anchorKey) {
            let p = NSPointFromString(s)
            if p != .zero { return p }
        }
        let f = (NSScreen.main ?? NSScreen.screens[0]).frame
        return CGPoint(x: f.maxX - 36, y: f.maxY - 120)   // right screen edge, near the top
    }
}
