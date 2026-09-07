import AppKit
import PortlyCore
import SwiftUI

@main
struct PortlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var supervisor = Supervisor.shared
    @AppStorage(PortlyPreferences.showMenuBarItemKey) private var showMenuBarItem = true
    @AppStorage(PortlyPreferences.showInDockKey) private var showInDock = true

    var body: some Scene {
        Window("Portly Custom", id: WindowOpener.mainWindowID) {
            MainView()
                .environmentObject(supervisor)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { WindowOpener.registerCurrentWindow() }
        }
        .defaultSize(width: 1080, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Coding Session") { StudioWorkspace.shared.perform(.newSession) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Shell Terminal") { StudioWorkspace.shared.perform(.newPane(.shell)) }
                    .keyboardShortcut("t", modifiers: .command)
            }
            StudioCommands()
        }

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarContent()
                .environmentObject(supervisor)
        } label: {
            MenuBarLabel(supervisor: supervisor)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: showMenuBarItem) { previous, visible in
            // Command-dragging the extra out writes this binding directly.
            var next = AppPresentation(showInDock: showInDock, showMenuBar: visible)
            next.setShowMenuBar(visible)
            let before = AppPresentation(showInDock: showInDock, showMenuBar: previous)
            guard next != before else { return }
            showInDock = next.showInDock
            showMenuBarItem = next.showMenuBar
            next.apply(activateIfRegular: before.usesAccessoryPolicy && !next.usesAccessoryPolicy)
        }

        Settings {
            SettingsView()
                .environmentObject(supervisor)
        }
    }
}

/// The menu bar glyph: the Portly mark, its process dot filled when something is
/// running, badged when something needs attention.
private struct MenuBarLabel: View {
    @ObservedObject var supervisor: Supervisor
    @ObservedObject private var keepAwake = KeepAwake.shared
    @AppStorage(PortlyPreferences.showMenuBarNameKey) private var showName = false

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: PortlyGlyph.menuBarImage(active: supervisor.runningCount > 0))
                .renderingMode(.template)

            if keepAwake.isActive {
                Image.nucleo(.coffee)
                    .resizable()
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Keeping the Mac awake")
            }

            if showName {
                Text("Portly")
            }

            if supervisor.hasProblem {
                NucleoIconView(.warning, size: 10)
            }
        }
        .accessibilityLabel("Portly")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var control: ControlServer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        LoginEnvironment.resolveIfNeeded()
        let presentation = AppPresentation.applyFromUserDefaults()
        WindowOpener.suppressMainWindowAtLaunch = presentation.usesAccessoryPolicy
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowOpener.hideMainWindowIfNeeded()
        PortlyPaths.ensureDirectories()
        Notifications.requestAuthorization()
        let server = ControlServer(supervisor: Supervisor.shared, port: Supervisor.shared.settings.apiPort)
        server.start()
        control = server
        Supervisor.shared.resumeAfterUpdaterRelaunchIfNeeded()
        // The AI usage rings: the notch on the screen edge and the sidebar
        // section read from the same store.
        UsageCenter.shared.start()
        // Private fork: no launch telemetry is sent anywhere.
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The app is the supervisor: quitting takes every server down with it.
        UsageCenter.shared.stop()
        KeepAwake.shared.shutdown()
        StudioWorkspace.shared.terminateEverything()
        Supervisor.shared.terminateEverythingSynchronously()
        control?.stop()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Bridges "open the window" requests coming from the menu bar and the control API.
///
/// The opener closure is captured from the menu bar scene, which is always alive,
/// so the window can be recreated even after it was closed.
enum WindowOpener {
    static let mainWindowID = "portly.main"
    static var opener: (() -> Void)?
    /// Accessory launches still instantiate the SwiftUI `Window` scene. Hide it
    /// once so menu-bar-only mode does not flash the main window, then allow
    /// later `Open Portly` requests to show it.
    static var suppressMainWindowAtLaunch = false

    static func registerCurrentWindow() {
        hideMainWindowIfNeeded()
    }

    static func hideMainWindowIfNeeded() {
        guard suppressMainWindowAtLaunch else { return }
        hideMainWindow()
    }

    static func openMainWindow() {
        DispatchQueue.main.async {
            suppressMainWindowAtLaunch = false
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(mainWindowID) == true }) {
                window.makeKeyAndOrderFront(nil)
                return
            }
            opener?()
        }
    }

    private static func hideMainWindow() {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(mainWindowID) == true
        }) else {
            return
        }
        window.orderOut(nil)
    }
}
