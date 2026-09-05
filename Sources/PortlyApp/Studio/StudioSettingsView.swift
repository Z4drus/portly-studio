import PortlyCore
import SwiftUI

/// Settings → Code: which agent new terminals start, text size, limits, and
/// the shortcut cheat sheet.
struct StudioSettingsView: View {
    @ObservedObject private var workspace = StudioWorkspace.shared
    @State private var customCommand = ""

    var body: some View {
        Form {
            Section("Default agent") {
                Picker("New terminals start", selection: agentBinding) {
                    ForEach(AgentPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                if workspace.config.defaultAgent == .custom {
                    TextField("Command", text: $customCommand, prompt: Text("claude --dangerously-skip-permissions"))
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(commitCustomCommand)
                        .onChange(of: customCommand) { commitCustomCommand() }
                } else if let command = workspace.config.agentLaunchCommand {
                    LabeledContent("Command") {
                        Text(command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Toggle("Launch the agent in every new terminal", isOn: Binding(
                    get: { workspace.config.launchAgentInNewPanes },
                    set: { value in workspace.updateSettings { $0.launchAgentInNewPanes = value } }
                ))

                Text("The command is typed into a fresh login shell at the project root, so your PATH, aliases and tools are all there. Turn the toggle off to get plain shells and start agents by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Terminals") {
                Stepper(
                    "Text size: \(Int(workspace.config.fontSize)) pt",
                    value: Binding(
                        get: { workspace.config.fontSize },
                        set: { value in workspace.updateSettings { $0.fontSize = value } }
                    ),
                    in: StudioConfig.minimumFontSize...StudioConfig.maximumFontSize,
                    step: 1
                )
                Stepper(
                    "Up to \(workspace.config.maxPanesPerSession) terminals per session",
                    value: Binding(
                        get: { workspace.config.maxPanesPerSession },
                        set: { value in workspace.updateSettings { $0.maxPanesPerSession = value } }
                    ),
                    in: 2...8
                )
                Text("⌘+ and ⌘− change one session's text size; this is the default for new ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard shortcuts") {
                shortcutRow("New coding session", "⌘N")
                shortcutRow("Split right / split down", "⌘D / ⇧⌘D")
                shortcutRow("New shell terminal", "⌘T")
                shortcutRow("Close the focused terminal", "⌘W")
                shortcutRow("Zoom the focused terminal", "⇧⌘↩")
                shortcutRow("Next / previous terminal", "⌘] / ⌘[")
                shortcutRow("Bigger / smaller / reset text", "⌘+ / ⌘− / ⌘0")
                shortcutRow("Quick terminal", "⌘J")
                shortcutRow("Environment files panel", "⇧⌘E")
                shortcutRow("Clear the focused terminal", "⌘K")
            }

            Section("Relaunch") {
                Toggle("Reopen every session at launch and resume its agents", isOn: Binding(
                    get: { workspace.config.reopenSessionsAtLaunch },
                    set: { value in workspace.updateSettings { $0.reopenSessionsAtLaunch = value } }
                ))
                Text("Shells restart at the project root. Claude Code conversations come back with --resume; other agents start fresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Sessions file") {
                    Text(NSString(string: StudioStore.defaultURL.path).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Session layouts persist; shells are respawned when a session is opened again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { customCommand = workspace.config.customAgentCommand }
    }

    private var agentBinding: Binding<AgentPreset> {
        Binding(
            get: { workspace.config.defaultAgent },
            set: { value in workspace.updateSettings { $0.defaultAgent = value } }
        )
    }

    private func commitCustomCommand() {
        let value = customCommand
        guard value != workspace.config.customAgentCommand else { return }
        workspace.updateSettings { $0.customAgentCommand = value }
    }

    private func shortcutRow(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys)
                .font(PortlyTypography.metric)
                .foregroundStyle(.secondary)
        }
    }
}
