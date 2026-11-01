import AppKit
import AgentBarCore

enum PresentationStyle: String, CaseIterable {
    case notch, pill, circle

    var title: String {
        switch self {
        case .notch: return "Notch"
        case .pill: return "Pill"
        case .circle: return "Circle"
        }
    }
}

/// Owns the active BarPresentation and switches between the three variants.
@MainActor
final class PresentationManager {
    private static let defaultsKey = "presentationStyle"
    private let environment: AppEnvironment
    private var current: BarPresentation?
    private(set) var style: PresentationStyle

    init(environment: AppEnvironment) {
        self.environment = environment
        let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(PresentationStyle.init(rawValue:))
        style = environment.options.presentation ?? saved ?? (hasNotch ? .notch : .pill)
    }

    func start() { show(style) }

    func select(_ newStyle: PresentationStyle) {
        guard newStyle != style || current == nil else { return }
        style = newStyle
        UserDefaults.standard.set(newStyle.rawValue, forKey: Self.defaultsKey)
        show(newStyle)
    }

    private func show(_ style: PresentationStyle) {
        current?.dismiss()
        let expanded = environment.options.demoExpanded
        let next: BarPresentation
        switch environment.backend {
        case .demo(let store): next = Self.make(style, store: store, expanded: expanded)
        case .live(let store): next = Self.make(style, store: store, expanded: expanded)
        }
        current = next
        next.present()
    }

    private static func make<S: SessionStoreReading & ResponseSink>(_ style: PresentationStyle, store: S, expanded: Bool) -> BarPresentation {
        switch style {
        case .notch: return NotchIslandPresentation(store: store, startExpanded: expanded)
        case .pill: return FloatingPillPresentation(store: store, startExpanded: expanded)
        case .circle: return DraggableCirclePresentation(store: store, startExpanded: expanded)
        }
    }
}
