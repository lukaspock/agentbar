import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let manager: PresentationManager

    /// Extension point: each factory is called whenever the menu opens; items are inserted above "Presentation".
    var extraMenuItems: [() -> NSMenuItem] = []

    /// Visible error state (e.g. transport failed to start): warning icon plus a disabled menu line.
    var errorMessage: String? {
        didSet {
            let name = errorMessage == nil ? "circle.inset.filled" : "exclamationmark.triangle.fill"
            let image = NSImage(systemSymbolName: name, accessibilityDescription: errorMessage ?? "AgentBar")
            image?.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.toolTip = errorMessage
        }
    }

    init(manager: PresentationManager) {
        self.manager = manager
        super.init()
        let image = NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: "AgentBar")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "AgentBar", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if let errorMessage {
            let e = NSMenuItem(title: errorMessage, action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        menu.addItem(.separator())
        if ChatHub.shared.backend != nil {
            let chat = NSMenuItem(title: "New chat session…", action: #selector(newChat), keyEquivalent: "n")
            chat.target = self
            menu.addItem(chat)
            menu.addItem(.separator())
        }
        for factory in extraMenuItems { menu.addItem(factory()) }
        if !extraMenuItems.isEmpty { menu.addItem(.separator()) }

        let styleItem = NSMenuItem(title: "Presentation style", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for style in PresentationStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == manager.style ? .on : .off
            sub.addItem(item)
        }
        styleItem.submenu = sub
        menu.addItem(styleItem)
        menu.addItem(toggleItem("Sound on new request", on: AttentionSettings.soundEnabled, action: #selector(toggleSound)))
        menu.addItem(toggleItem("Auto-expand on new request", on: AttentionSettings.autoExpandEnabled, action: #selector(toggleAutoExpand)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AgentBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func toggleItem(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func newChat() { NewChatFlow.run() }

    @objc private func toggleSound() { AttentionSettings.soundEnabled.toggle() }
    @objc private func toggleAutoExpand() { AttentionSettings.autoExpandEnabled.toggle() }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = PresentationStyle(rawValue: raw) else { return }
        manager.select(style)
    }
}
