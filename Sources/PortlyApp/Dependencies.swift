import AppKit
import Foundation
import SwiftTerm
import SwiftUI

/// Whether a Node project has its packages installed, and which tool installs
/// them. Nil from the inspector means "not a Node project", no gating.
struct DependencyStatus: Equatable {
    enum PackageManager: String, Equatable {
        case pnpm
        case bun
        case yarn
        case npm

        var installCommand: String {
            switch self {
            case .pnpm: return "pnpm install"
            case .bun: return "bun install"
            case .yarn: return "yarn install"
            case .npm: return "npm install"
            }
        }

        var displayName: String { rawValue }
    }

    let manager: PackageManager
    /// Where `package.json` lives; the install runs there.
    let packageDirectory: String
    let installed: Bool
}

enum DependencyInspector {
    /// Walks up from the working directory to the project root looking for a
    /// `package.json`; `node_modules` anywhere on that path counts, because
    /// workspaces hoist to their root.
    static func inspect(workingDirectory: String, projectRoot: String) -> DependencyStatus? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath).standardizedFileURL
        var directory = URL(fileURLWithPath: NSString(string: workingDirectory).expandingTildeInPath).standardizedFileURL

        var packageDirectory: URL?
        var chain: [URL] = []
        while true {
            chain.append(directory)
            if packageDirectory == nil, fm.fileExists(atPath: directory.appendingPathComponent("package.json").path) {
                packageDirectory = directory
            }
            if directory.path == root.path || directory.path == "/" || !directory.path.hasPrefix(root.path) { break }
            directory = directory.deletingLastPathComponent()
        }
        guard let packageDirectory else { return nil }

        let installed = chain.contains { hasInstalledModules(at: $0) }
        return DependencyStatus(
            manager: packageManager(chain: chain),
            packageDirectory: packageDirectory.path,
            installed: installed
        )
    }

    private static func hasInstalledModules(at directory: URL) -> Bool {
        let modules = directory.appendingPathComponent("node_modules")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: modules.path) else { return false }
        // A bare `.bin` or `.pnpm` folder left by a failed install does not count.
        return entries.contains { !$0.hasPrefix(".") }
    }

    private static func packageManager(chain: [URL]) -> DependencyStatus.PackageManager {
        let fm = FileManager.default
        let lockfiles: [(String, DependencyStatus.PackageManager)] = [
            ("pnpm-lock.yaml", .pnpm), ("bun.lockb", .bun), ("bun.lock", .bun),
            ("yarn.lock", .yarn), ("package-lock.json", .npm),
        ]
        for directory in chain {
            for (file, manager) in lockfiles where fm.fileExists(atPath: directory.appendingPathComponent(file).path) {
                return manager
            }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let declared = json["packageManager"] as? String {
                if declared.hasPrefix("pnpm") { return .pnpm }
                if declared.hasPrefix("bun") { return .bun }
                if declared.hasPrefix("yarn") { return .yarn }
                if declared.hasPrefix("npm") { return .npm }
            }
        }
        return .pnpm
    }
}

enum DependencyInstallState: Equatable {
    case idle
    case installing
    case failed(exitCode: Int32?)

    var isInstalling: Bool { self == .installing }
}

/// Runs one install command in a PTY, streaming into the server's terminal.
final class DependencyInstallProcess: NSObject, LocalProcessDelegate {
    private var process: LocalProcess?
    private let onOutput: (ArraySlice<UInt8>) -> Void
    private let onExit: (Int32?) -> Void
    private let windowSize: () -> winsize

    init(
        windowSize: @escaping () -> winsize,
        onOutput: @escaping (ArraySlice<UInt8>) -> Void,
        onExit: @escaping (Int32?) -> Void
    ) {
        self.windowSize = windowSize
        self.onOutput = onOutput
        self.onExit = onExit
        super.init()
    }

    func start(command: String, directory: String, environment: [String]) {
        let proc = LocalProcess(delegate: self)
        process = proc
        proc.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", command],
            environment: environment,
            execName: nil,
            currentDirectory: directory
        )
    }

    var isRunning: Bool { process?.running ?? false }

    func terminate() {
        guard let process, process.running, process.shellPid > 0 else { return }
        kill(-process.shellPid, SIGTERM)
        kill(process.shellPid, SIGTERM)
    }

    func send(data: ArraySlice<UInt8>) {
        process?.send(data: data)
    }

    func resize(cols: Int, rows: Int) {
        guard let process, process.running, process.childfd >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let normalized = ServerRuntime.normalizedProcessExitCode(exitCode)
        DispatchQueue.main.async { [weak self] in
            self?.process = nil
            self?.onExit(normalized)
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        onOutput(slice)
    }

    func getWindowSize() -> winsize {
        windowSize()
    }
}

// MARK: - UI

/// A thin, endlessly sweeping highlight: activity without a fake percentage.
struct IndeterminateBar: View {
    var tint: SwiftUI.Color = .accentColor
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0), tint, tint.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 0.38)
                    .offset(x: phase * width)
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
        .onAppear {
            phase = -0.4
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .accessibilityLabel("In progress")
    }
}

/// The install button and its states, shared by the stopped placeholder and
/// the info bar: one control that becomes a spinner, then disappears.
struct InstallDependenciesButton: View {
    @ObservedObject var runtime: ServerRuntime
    var prominent = true

    var body: some View {
        if let dependencies = runtime.dependencies, !dependencies.installed || runtime.dependencyInstall.isInstalling {
            Button {
                runtime.installDependencies()
            } label: {
                HStack(spacing: 7) {
                    if runtime.dependencyInstall.isInstalling {
                        ProgressView()
                            .controlSize(.small)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    } else {
                        NucleoIconView(.download, size: 12)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                    Text(label(dependencies))
                        .contentTransition(.opacity)
                }
                .animation(Motion.state, value: runtime.dependencyInstall.isInstalling)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(prominent ? .large : .small)
            .disabled(runtime.dependencyInstall.isInstalling)
            .help("Runs \(dependencies.manager.installCommand) in \(NSString(string: dependencies.packageDirectory).abbreviatingWithTildeInPath)")
        }
    }

    private func label(_ dependencies: DependencyStatus) -> String {
        switch runtime.dependencyInstall {
        case .installing: return "Installing with \(dependencies.manager.displayName)…"
        case .failed: return "Retry install"
        case .idle: return "Install dependencies"
        }
    }
}
