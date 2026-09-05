import AppKit
import ApplicationServices
import SwiftUI

/// The two macOS grants that let agents inside Portly reach the whole Mac:
/// Full Disk Access (Downloads, Documents, other apps' data) and
/// Accessibility (driving other applications). Shells started by Portly
/// inherit both from the app.
enum SystemAccess {
    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Readable only with Full Disk Access; every account has it.
        let probes = [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
        ]
        for probe in probes where FileManager.default.fileExists(atPath: probe) {
            let descriptor = Darwin.open(probe, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            return false
        }
        return false
    }

    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that points at Privacy & Security → Accessibility.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Polls the grants while the card is on screen; System Settings changes them
/// behind the app's back.
final class SystemAccessStatus: ObservableObject {
    @Published private(set) var fullDiskAccess = false
    @Published private(set) var accessibility = false

    private var timer: Timer?

    init() {
        refresh()
    }

    var isComplete: Bool { fullDiskAccess && accessibility }

    func refresh() {
        fullDiskAccess = SystemAccess.hasFullDiskAccess()
        accessibility = SystemAccess.hasAccessibility()
    }

    func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

/// Onboarding card, same shape as the agent setup one.
struct SystemAccessCard: View {
    @ObservedObject var status: SystemAccessStatus
    let onDismiss: () -> Void

    @AppStorage("accessibilityPrompted") private var accessibilityPrompted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                NucleoIconView(status.isComplete ? .badgeCheck : .shield, size: 19)
                    .foregroundStyle(status.isComplete ? .green : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill((status.isComplete ? Color.green : Color.accentColor).opacity(0.12))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(status.isComplete ? "Portly has the run of your Mac" : "Give Portly the run of your Mac")
                        .font(PortlyTypography.project)
                    Text(status.isComplete
                        ? "Agents started here can reach Downloads, Documents, global configs and other apps."
                        : "Agents inherit Portly's permissions. Two grants in System Settings cover Downloads, Documents, global configs and other apps.")
                        .font(PortlyTypography.body)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if status.isComplete {
                    Button("Done", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Not now", action: onDismiss)
                        .buttonStyle(.borderless)
                }
            }

            if !status.isComplete {
                HStack(spacing: 10) {
                    SetupStep(
                        number: 1,
                        title: status.fullDiskAccess ? "Full Disk Access granted" : "Full Disk Access",
                        detail: "Open the list, press +, pick Portly Custom in Applications and turn it on.",
                        isComplete: status.fullDiskAccess
                    ) {
                        HStack(spacing: 6) {
                            Button("Reveal app") { SystemAccess.revealApp() }
                                .buttonStyle(.bordered)
                                .help("Shows Portly Custom in the Finder, ready to drag into the list")
                            Button(status.fullDiskAccess ? "Granted" : "Open Settings") {
                                SystemAccess.openFullDiskAccessSettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(status.fullDiskAccess)
                        }
                    }

                    SetupStep(
                        number: 2,
                        title: status.accessibility ? "Accessibility granted" : "Accessibility",
                        detail: "Lets agents drive other apps and system settings on your behalf.",
                        isComplete: status.accessibility
                    ) {
                        Button(status.accessibility ? "Granted" : "Grant access") {
                            SystemAccess.requestAccessibility()
                            SystemAccess.openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(status.accessibility)
                    }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("System access setup")
        .onAppear {
            status.refresh()
            status.startPolling()
            // Ask once, right away: the system sheet explains the rest.
            if !status.accessibility, !accessibilityPrompted {
                accessibilityPrompted = true
                SystemAccess.requestAccessibility()
            }
        }
        .onDisappear { status.stopPolling() }
    }
}

/// Settings → General rows for the same two grants.
struct SystemAccessSettingsRows: View {
    @ObservedObject var status: SystemAccessStatus

    var body: some View {
        LabeledContent("Full Disk Access") {
            HStack(spacing: 8) {
                grant(status.fullDiskAccess)
                Button("Open Settings") { SystemAccess.openFullDiskAccessSettings() }
                    .controlSize(.small)
            }
        }
        LabeledContent("Accessibility") {
            HStack(spacing: 8) {
                grant(status.accessibility)
                Button(status.accessibility ? "Open Settings" : "Grant access") {
                    if !status.accessibility { SystemAccess.requestAccessibility() }
                    SystemAccess.openAccessibilitySettings()
                }
                .controlSize(.small)
            }
        }
        Text("Agents started from Portly inherit these permissions. The app is signed with a fixed identity so the grants survive rebuilds.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func grant(_ granted: Bool) -> some View {
        HStack(spacing: 5) {
            NucleoIconView(granted ? .checkCircle : .xmarkCircle, size: 11)
            Text(granted ? "Granted" : "Not granted")
        }
        .font(PortlyTypography.metadata)
        .foregroundStyle(granted ? Color.green : Color.orange)
    }
}
