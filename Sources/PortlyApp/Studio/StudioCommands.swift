import SwiftUI

/// The Terminal menu: every session shortcut, routed to the session on screen.
struct StudioCommands: Commands {
    var body: some Commands {
        CommandMenu("Terminal") {
            Button("Split Right") { StudioWorkspace.shared.perform(.splitRight) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { StudioWorkspace.shared.perform(.splitDown) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("New Agent Terminal") { StudioWorkspace.shared.perform(.newPane(.agent)) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Close Terminal") { StudioWorkspace.shared.perform(.closePane) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Zoom Terminal") { StudioWorkspace.shared.perform(.toggleZoom) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Next Terminal") { StudioWorkspace.shared.perform(.focusNext) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Terminal") { StudioWorkspace.shared.perform(.focusPrevious) }
                .keyboardShortcut("[", modifiers: .command)
            Divider()
            Button("Bigger Text") { StudioWorkspace.shared.perform(.biggerText) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Smaller Text") { StudioWorkspace.shared.perform(.smallerText) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Default Text Size") { StudioWorkspace.shared.perform(.resetText) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Clear Terminal") { StudioWorkspace.shared.perform(.clearTerminal) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Quick Terminal") { StudioWorkspace.shared.perform(.toggleQuickTerminal) }
                .keyboardShortcut("j", modifiers: .command)
            Button("Environment Files…") { StudioWorkspace.shared.perform(.editEnvironment) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}
