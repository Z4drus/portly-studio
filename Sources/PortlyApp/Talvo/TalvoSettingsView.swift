import PortlyCore
import SwiftUI

/// Settings → Talvo: where Talvo lives, the device token, and what is linked.
struct TalvoSettingsView: View {
    @ObservedObject private var center = TalvoCenter.shared
    @ObservedObject private var workspace = StudioWorkspace.shared
    @ObservedObject private var supervisor = Supervisor.shared
    @State private var server = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        Form {
            Section("Connection") {
                if center.connection.isConfigured, let identity = center.identity {
                    LabeledContent("Signed in as") {
                        HStack(spacing: 8) {
                            TalvoAvatar(user: identity.user, size: 18)
                            Text(identity.user.name)
                            Text(identity.user.email)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Server", value: TalvoCredentials.serverURL?.host ?? "")
                    LabeledContent("Token") {
                        Text("\(identity.token.name) · \(identity.token.prefix)… · \(identity.canWrite ? "read and write" : "read only")")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Stream", value: connectionLabel)
                    if let lastSync = center.lastSyncAt {
                        LabeledContent("Last sync") {
                            Text("\(lastSync.formatted(date: .omitted, time: .standard)) · sequence \(center.data.seq)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    HStack {
                        Button("Reconnect") { center.reconnectNow() }
                        Button("Disconnect", role: .destructive) {
                            center.disconnect()
                            token = ""
                            message = nil
                        }
                    }
                } else if center.connection.isConfigured {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(connectionLabel)
                            .foregroundStyle(.secondary)
                    }
                    Button("Disconnect", role: .destructive) { center.disconnect() }
                } else {
                    TextField("Server", text: $server, prompt: Text("talvo.bleeze.ch"))
                        .textFieldStyle(.roundedBorder)
                    SecureField("Device token", text: $token, prompt: Text("tlv_…"))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(connecting ? "Connecting…" : "Connect") { connect() }
                            .disabled(connecting || token.trimmingCharacters(in: .whitespaces).isEmpty || server.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                    Text("In Talvo, open your profile and add a device under Appareils: it shows the token once. The token is stored in your keychain and never leaves this Mac except to reach the server above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                }
            }

            if center.connection.isConfigured {
                Section("Linked projects") {
                    let links = workspace.config.talvoLinks
                    if links.isEmpty {
                        Text("No project linked yet. Open a project and use the Talvo button at the left of the toolbar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(supervisor.projects.filter { links[$0.id] != nil }) { project in
                            LabeledContent(project.name) {
                                HStack(spacing: 8) {
                                    if let talvo = links[project.id].flatMap({ center.data.projects[$0] }) {
                                        NucleoIconView(TalvoIcons.glyph(for: talvo.icon, fallback: .talvo), size: 12)
                                            .foregroundStyle(Color(hex: talvo.color))
                                        Text(talvo.name)
                                    } else {
                                        Text("Unknown Talvo project")
                                            .foregroundStyle(.secondary)
                                    }
                                    Button("Unlink") { workspace.linkTalvoProject(nil, to: project.id) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Section("How it stays current") {
                    Text("Portly keeps one event stream open to Talvo. Each change sends a sequence number, and Portly fetches only what moved since the one it holds, so a change made in Talvo shows here within a second for a few kilobytes an hour. A copy of the light records lives in ~/.config/portly/talvo-cache.json; long texts are read when opened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            server = TalvoCredentials.serverURL?.host ?? ""
        }
    }

    private var connectionLabel: String {
        switch center.connection {
        case .off: return "Off"
        case .connecting: return "Connecting…"
        case .live: return "Live"
        case .offline(let reason): return "Reconnecting · \(reason)"
        case .refused(let reason): return "Refused · \(reason)"
        }
    }

    private func connect() {
        connecting = true
        message = nil
        let server = self.server
        let token = self.token
        Task {
            do {
                let identity = try await center.connect(serverText: server, token: token)
                message = "Connected as \(identity.user.name)."
                messageIsError = false
                self.token = ""
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            connecting = false
        }
    }
}
