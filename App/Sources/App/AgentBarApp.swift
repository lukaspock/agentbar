import AppKit
import AgentBarCore

@main
struct AgentBarApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Other agents/integration can append menu item factories here before launch finishes
/// (e.g. `AppHooks.menuItemFactories.append { HookSetup.menuItem() }`).
@MainActor
enum AppHooks {
    static var menuItemFactories: [() -> NSMenuItem] = []
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var presentations: PresentationManager?
    private var menu: MenuBarController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment()
        var startupError: String?
        do { try env.startTransport() } catch TransportServer.ServerError.alreadyRunning {
            // A second instance quits quietly; it never touched the first instance's socket or token.
            exit(0)
        } catch { startupError = "Transport could not start: \(error)" }
        let manager = PresentationManager(environment: env)
        let menu = MenuBarController(manager: manager)
        AppHooks.menuItemFactories.append(HookSetupMenu.menuItemFactory)
        AppHooks.menuItemFactories.append(CodexHookSetupMenu.menuItemFactory)
        menu.extraMenuItems = AppHooks.menuItemFactories
        menu.errorMessage = startupError
        SetupCoordinator.shared.configure(options: env.options, hostClient: env.server?.hostClient)
        menu.setupAction = { SetupCoordinator.shared.show() }
        environment = env
        presentations = manager
        self.menu = menu
        manager.start()
        // Give the host channel a moment to connect before the (read-only) probes run.
        DispatchQueue.main.asyncAfter(deadline: .now() + (env.options.demoOnboarding != nil ? 0.6 : 2.0)) {
            SetupCoordinator.shared.showAtLaunchIfNeeded()
        }
        if env.options.demoNewChat { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NewChatFlow.run() } }
        if env.options.demoAgentUser { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { PanelRouter.shared.openAgentUser() } }
        // SIGTERM/SIGINT (e.g. `pkill AgentBar`) go through a normal quit so socket and token get removed.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.stopTransport()
    }
}
