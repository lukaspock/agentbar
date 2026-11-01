import SwiftUI
import AppKit

/// Geometry/appearance parameters of one presentation variant. All sizes in points.
struct BarLayout {
    var collapsedSize: CGSize
    var expandedWidth: CGFloat = 380
    var maxHeight: CGFloat = 520
    var collapsedRadii: RectangleCornerRadii
    var expandedRadii: RectangleCornerRadii
    var expandedTopPadding: CGFloat      // space above panel content (notch height for the notch variant)
    var windowTopInset: CGFloat          // gap between screen top and the shape
    var dotAlignment: Alignment
    var dotSize: CGFloat
    var dotTrailingPadding: CGFloat = 0
    var draggable = false

    static let windowSize = CGSize(width: 800, height: 560)

    static func make(style: PresentationStyle, notch: NotchMetrics, screen: NSScreen) -> BarLayout {
        func radii(_ tl: CGFloat, _ bl: CGFloat, _ br: CGFloat, _ tr: CGFloat) -> RectangleCornerRadii {
            RectangleCornerRadii(topLeading: tl, bottomLeading: bl, bottomTrailing: br, topTrailing: tr)
        }
        switch style {
        case .notch:
            return BarLayout(collapsedSize: CGSize(width: notch.size.width + 64, height: notch.size.height),
                             collapsedRadii: radii(0, 10, 10, 0), expandedRadii: radii(0, 26, 26, 0),
                             expandedTopPadding: notch.size.height + 6, windowTopInset: 0,
                             dotAlignment: .trailing, dotSize: 20, dotTrailingPadding: 12)
        case .pill:
            let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
            let below = screen.safeAreaInsets.top > 0
            return BarLayout(collapsedSize: CGSize(width: 64, height: 26),
                             collapsedRadii: radii(11, 11, 11, 11), expandedRadii: radii(22, 22, 22, 22),
                             expandedTopPadding: 10, windowTopInset: below ? barHeight + 4 : 2,
                             dotAlignment: .center, dotSize: 20)
        case .circle:
            return BarLayout(collapsedSize: CGSize(width: 30, height: 30),
                             collapsedRadii: radii(13, 13, 13, 13), expandedRadii: radii(22, 22, 22, 22),
                             expandedTopPadding: 10, windowTopInset: 0,
                             dotAlignment: .center, dotSize: 24, draggable: true)
        }
    }
}

struct NotchMetrics {
    var screen: NSScreen
    var size: CGSize
    var centerX: CGFloat
    var hasNotch: Bool

    static func current() -> NotchMetrics {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - l.width - r.width
            return NotchMetrics(screen: screen, size: CGSize(width: width, height: screen.safeAreaInsets.top),
                                centerX: (l.maxX + r.minX) / 2, hasNotch: true)
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        return NotchMetrics(screen: screen, size: CGSize(width: 190, height: 32), centerX: screen.frame.midX, hasNotch: false)
    }
}

enum DragPhase { case changed, ended }

/// Shared UI state of one bar instance: hover/expand logic, selection, text-editing state.
@MainActor
final class BarViewModel: ObservableObject {
    @Published var layout: BarLayout
    @Published var expanded: Bool
    @Published var offsetX: CGFloat = 0
    @Published var selectedSessionId: String?
    @Published private(set) var isEditing = false

    /// Visible shape in window coordinates (top-left origin); written by the view, read by the pointer poll.
    var contentHeight: CGFloat = 160   // measured height of the expanded content (written by the shell)
    let pinnedExpanded: Bool
    var keyHandler: ((Bool) -> Void)?
    var onDrag: ((DragPhase) -> Void)?

    private var collapseWork: DispatchWorkItem?
    private var pointerInside = false

    init(layout: BarLayout, startExpanded: Bool) {
        self.layout = layout
        self.expanded = startExpanded
        self.pinnedExpanded = startExpanded
    }

    func pointerChanged(_ inside: Bool) {
        pointerInside = inside
        if inside {
            collapseWork?.cancel(); collapseWork = nil
            if !expanded { expanded = true }
        } else if expanded, !isEditing, !pinnedExpanded, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.collapseWork = nil
                    if !self.pointerInside && !self.isEditing { self.expanded = false }
                }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    func setEditing(_ editing: Bool) {
        guard editing != isEditing else { return }
        isEditing = editing
        keyHandler?(editing)
        if !editing { pointerChanged(pointerInside) }
    }
}
