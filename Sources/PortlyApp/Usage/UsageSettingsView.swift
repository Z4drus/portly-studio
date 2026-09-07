import AppKit
import SwiftUI

/// Settings → AI Usage: which assistants Portly reads, and where the readings
/// show up.
struct UsageSettingsView: View {
    @ObservedObject private var center = UsageCenter.shared
    @ObservedObject private var store: UsageStore
    @ObservedObject private var preferences: UsagePreferences
    /// Re-read whenever the window comes forward: switching account happens
    /// in another app, so the user is always coming *back* here to see it.
    @State private var accounts: [ProviderSummary] = []
    @State private var now = Date()

    init() {
        let center = UsageCenter.shared
        _store = ObservedObject(wrappedValue: center.store)
        _preferences = ObservedObject(wrappedValue: center.preferences)
    }

    var body: some View {
        Form {
            Section("Assistants") {
                if needsSetup { setupNote }
                ForEach(accounts) { provider in
                    ProviderAccountRow(
                        provider: provider,
                        isEnabled: preferences.isEnabled(provider.id),
                        setEnabled: { center.setEnabled($0, for: provider.id) },
                        retry: { center.refresh(providerID: provider.id) }
                    )
                }
                Text("Portly never signs in anywhere. Each reading is borrowed from the tool that already holds the account: Claude Code's keychain token, Cursor's editor session, Codex's and Grok's local sign-in. Switching one off stops its credential being read and forgets its readings; it does not sign you out of that tool. macOS asks once before Claude Code's token can be read — choose Always Allow so it stays quiet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Where the readings appear") {
                Picker("Notch", selection: $preferences.notchVisibility) {
                    ForEach(NotchVisibility.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(preferences.notchVisibility.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Edge", selection: $preferences.notchEdge) {
                    ForEach(NotchEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(preferences.notchVisibility == .hidden)

                Text(preferences.notchEdge.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Section above Resources in the sidebar", isOn: $preferences.showInSidebar)
                Toggle("Rows in the menu bar popover", isOn: $preferences.showInMenuBar)
                Text("The three surfaces are independent: keep the notch alone, the sidebar alone, only the menu bar in menu-bar-only mode, or any mix. Hover a ring in the notch for its windows and reset times; click a ring to refresh it, click elsewhere on the open notch to keep it open, right-click for the menu.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("What the rings show") {
                Picker("Ring follows", selection: $preferences.headline) {
                    ForEach(UsageHeadline.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(preferences.headline.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Per-model weekly windows (Fable, Opus, Sonnet…)", isOn: $preferences.showPerModelWindows)
                Text("Claude meters Fable and the other model families against their own share of the week. Off, only the current session and the all-models week are listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Live Claude Code sessions", isOn: $preferences.showSessions)
                Text("A thin arc turns inside the Claude ring while a session is working anywhere on this Mac, amber when one is waiting for you; the tooltip and the sidebar list them by name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Readings") {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.lastRefreshedAt.map { "Updated \(ElapsedCopy.ago(since: $0, now: now))" } ?? "Waiting for the first reading…")
                            .font(PortlyTypography.bodyMedium)
                        Text("Polled every minute while an agent is working, every five minutes otherwise, and again when the Mac wakes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Refresh Now") { store.refreshNow() }
                        .disabled(!store.refreshing.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: preferences.enabledProviders) { reload() }
        .onChange(of: store.refusedAccess) { reload() }
    }

    private func reload() {
        accounts = store.providerSummaries
        now = Date()
    }

    /// Nothing to read from anywhere: the only moment the screen has
    /// something to explain.
    private var needsSetup: Bool {
        !accounts.isEmpty && accounts.allSatisfy { $0.account == nil }
    }

    private var setupNote: some View {
        HStack(alignment: .top, spacing: 10) {
            NucleoIconView(.sparkle, size: 16)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect an assistant to get started")
                    .font(PortlyTypography.bodyMedium)
                Text("Portly reads usage from tools already signed in on this Mac and never asks for a password. Sign in to Claude Code (the terminal tool, not the Claude app), Cursor, Codex or Grok, switch it on here, and its ring appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// One assistant: whether Portly reads it, whose account that is, and where to
/// go if there is nothing to read.
private struct ProviderAccountRow: View {
    let provider: ProviderSummary
    let isEnabled: Bool
    let setEnabled: (Bool) -> Void
    /// Re-reads the credential. For a declined keychain prompt that is the
    /// whole remedy: asking again is what puts the prompt back on screen.
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                ProviderGlyphView(glyph: provider.glyph, size: 16)
                    .foregroundStyle(isEnabled ? .primary : .tertiary)

                Text(provider.name)
                    .foregroundStyle(isEnabled ? .primary : .secondary)

                Spacer(minLength: 8)

                if isEnabled, provider.wasRefusedAccess {
                    Button("Allow access…", action: retry)
                        .controlSize(.small)
                        .help("Asks macOS for \(provider.name)'s saved login again. Choose Always Allow and it will stop asking.")
                }

                if isEnabled, let destination {
                    Button(destination.title) { open(destination) }
                        .controlSize(.small)
                        .help(destination.help)
                }

                Toggle("", isOn: Binding(get: { isEnabled }, set: setEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(isEnabled
                        ? "Switch off to stop reading \(provider.name) and forget its readings."
                        : "Switch on to read \(provider.name)'s usage.")
                    .accessibilityLabel("Track \(provider.name)")
            }

            detail
                .font(.caption)
                .padding(.leading, 26)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !isEnabled {
            Text("Not tracked — nothing is read, and no readings are kept.")
                .foregroundStyle(.tertiary)
        } else if let account = provider.account {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.summary)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(provider.signIn.switchHint)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if provider.wasRefusedAccess {
            Text("macOS is not letting Portly read \(provider.name)'s saved login. Choose Allow access… above, then Always Allow.")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(provider.signIn.explanation)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where this row's "Open" button goes: the owning app when installed,
    /// the vendor's usage page otherwise.
    private enum Destination {
        case app(URL, name: String)
        case website(URL, host: String)

        var title: String {
            switch self {
            case .app(_, let name): return "Open \(name)"
            case .website(_, let host): return "Open \(host)"
            }
        }

        var help: String {
            switch self {
            case .app(_, let name):
                return "Opens \(name), which is where this account is signed in."
            case .website(_, let host):
                return "Opens \(host) in your browser. That site has its own sign-in, separate from the credential read here."
            }
        }
    }

    private var destination: Destination? {
        if case .openApp(let bundleID, let name) = provider.signIn,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return .app(app, name: name)
        }
        if let url = provider.account?.manageURL, let host = url.host {
            return .website(url, host: host)
        }
        return nil
    }

    private func open(_ destination: Destination) {
        switch destination {
        case .app(let url, _):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .website(let url, _):
            NSWorkspace.shared.open(url)
        }
    }
}
