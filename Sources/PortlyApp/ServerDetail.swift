import AppKit
import PortlyCore
import SwiftUI

/// The terminal plus everything you need to act on one server.
struct ServerDetail: View {
    @ObservedObject var runtime: ServerRuntime
    let onEdit: () -> Void

    @EnvironmentObject private var supervisor: Supervisor
    @State private var conflict: PortOccupant?
    @State private var showsResources = false
    @State private var conflictActionError: String?
    @State private var acknowledgedFallbackPort: Int?

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            Divider()
            // The conflict is found by an async lsof, so it lands well after the
            // pane is drawn. Sliding it down from the top edge makes it read as
            // a banner arriving rather than the terminal jumping.
            if let conflict, !conflict.ownedByPortly {
                VStack(spacing: 0) {
                    conflictBanner(conflict)
                    Divider()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let fallback = runtime.portFallback, acknowledgedFallbackPort != fallback.usedPort {
                VStack(spacing: 0) {
                    fallbackBanner(fallback)
                    Divider()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if runtime.dependencyInstall.isInstalling {
                VStack(spacing: 0) {
                    installBanner
                    Divider()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if case .failed(let code) = runtime.dependencyInstall {
                VStack(spacing: 0) {
                    installFailedBanner(code)
                    Divider()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if runtime.state == .stopped, !runtime.isInstallingDependencies {
                stoppedState
                    .transition(.opacity)
            } else {
                TerminalPane(runtime: runtime)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(Motion.banner, value: conflict?.pid)
        .animation(Motion.banner, value: runtime.dependencyInstall)
        .animation(Motion.banner, value: runtime.portFallback)
        .animation(Motion.banner, value: acknowledgedFallbackPort)
        .animation(Motion.paneSwap, value: runtime.state == .stopped)
        .animation(Motion.paneSwap, value: runtime.isInstallingDependencies)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    if runtime.isRunning {
                        runtime.stop()
                    } else {
                        runtime.start()
                    }
                } label: {
                    NucleoLabel(runtime.isRunning ? "Stop" : runtime.state == .failed ? "Retry" : "Start", icon: runtime.isRunning ? .stop : runtime.state == .failed ? .restart : .play)
                    .contentTransition(.opacity)
                }
                .animation(Motion.state, value: runtime.isRunning)
                .disabled(!runtime.isRunning && !runtime.canStart)
                .help(
                    runtime.isRunning
                        ? "Stop the server"
                        : !runtime.canStart
                            ? "Install the dependencies first"
                            : runtime.state == .failed
                                ? "Reset retries and start the server"
                                : "Start the server"
                )

                if runtime.isRunning {
                    Button { runtime.restart() } label: { NucleoLabel("Restart", icon: .restart) }
                        .help("Restart the server")
                }

                if !runtime.config.actions.isEmpty {
                    Menu {
                        ForEach(Array(runtime.config.actions.enumerated()), id: \.offset) { _, action in
                            Button(action.name) {
                                supervisor.runAction(action, for: runtime)
                            }
                        }
                    } label: {
                        NucleoLabel(runtime.runningAction.map { "Running \($0.name)…" } ?? "Actions", icon: .bolt)
                    }
                    .disabled(runtime.runningAction != nil || runtime.isInstallingDependencies)
                    .help(runtime.runningAction == nil
                        ? "Run a maintenance action beside the server; its output goes to this terminal"
                        : "Wait for the current action to finish")
                }

                if let url = runtime.url {
                    if runtime.extraPorts.isEmpty {
                        Button {
                            if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                        } label: {
                            NucleoLabel("Open", icon: .browser)
                        }
                        .help("Open \(url)")
                    } else {
                        Menu {
                            ForEach([runtime.effectivePort].compactMap { $0 } + runtime.extraPorts, id: \.self) { port in
                                Button("http://localhost:\(String(port))") {
                                    if let link = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(link) }
                                }
                            }
                        } label: {
                            NucleoLabel("Open", icon: .browser)
                        }
                        .help("This server listens on several ports")
                    }
                }

                if runtime.state != .stopped {
                    Button { runtime.clearTerminal() } label: { NucleoLabel("Clear", icon: .eraser) }
                        .help("Clear the terminal")
                }

                Button(action: onEdit) { NucleoLabel("Edit", icon: .sliders) }
                    .help("Edit this server")
            }
        }
        .navigationTitle(runtime.config.name)
        .navigationSubtitle(runtime.projectName)
        .onAppear {
            refreshConflict()
            runtime.refreshDependencies()
        }
        .onChange(of: runtime.state) { refreshConflict() }
        // A `pnpm install` run from any terminal should flip the button off by
        // itself, so poll the folder while packages are missing.
        .onReceive(Self.dependencyPoll) { _ in
            if runtime.dependencies?.installed == false || runtime.isInstallingDependencies {
                runtime.refreshDependencies()
            }
        }
        .alert("Unable to stop port owner", isPresented: Binding(
            get: { conflictActionError != nil },
            set: { if !$0 { conflictActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conflictActionError ?? "The port owner could not be stopped.")
        }
    }

    private static let dependencyPoll = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private func fallbackBanner(_ fallback: ServerRuntime.PortFallback) -> some View {
        HStack(spacing: 10) {
            NucleoIconView(.info, size: 14)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Running on port \(fallback.usedPort)")
                    .font(.system(size: 12, weight: .medium))
                Text("Port \(fallback.requestedPort) is used by \(fallback.occupantCommand) (pid \(fallback.occupantPID)). Portly picked the next free one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Keep \(fallback.usedPort)") {
                acknowledgedFallbackPort = fallback.usedPort
            }
            .controlSize(.small)
            Button("Take port \(fallback.requestedPort)") {
                runtime.reclaimConfiguredPort()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .help("Stops \(fallback.occupantCommand), waits for the port, then restarts this server on \(fallback.requestedPort)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.1))
    }

    private var installBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Installing dependencies")
                        .font(.system(size: 12, weight: .medium))
                    if let dependencies = runtime.dependencies {
                        Text("\(dependencies.manager.installCommand) · \(NSString(string: dependencies.packageDirectory).abbreviatingWithTildeInPath)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Button("Cancel") { runtime.cancelDependencyInstall() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            IndeterminateBar()
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
        .background(Color.accentColor.opacity(0.08))
    }

    private func installFailedBanner(_ code: Int32?) -> some View {
        HStack(spacing: 10) {
            NucleoIconView(.warning, size: 14)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(code.map { "Install failed with exit code \($0)" } ?? "Install was interrupted")
                    .font(.system(size: 12, weight: .medium))
                Text("The output stays in the terminal below. Fix the cause, then try again.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            InstallDependenciesButton(runtime: runtime, prominent: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    private var stoppedState: some View {
        VStack(spacing: 12) {
            NucleoIconView(.terminal, size: 32)
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Server is stopped")
                    .font(PortlyTypography.title)
                Text("Start \(runtime.config.name) to see its live terminal output.")
                    .font(PortlyTypography.body)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                InstallDependenciesButton(runtime: runtime)
                Button {
                    runtime.start()
                } label: {
                    NucleoLabel("Start", icon: .play)
                }
                .buttonStyle(runtime.canStart ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
                .controlSize(.large)
                .disabled(!runtime.canStart)
            }
            .animation(Motion.state, value: runtime.canStart)

            if let dependencies = runtime.dependencies, !dependencies.installed, !runtime.isInstallingDependencies {
                Text("No node_modules in \(NSString(string: dependencies.packageDirectory).lastPathComponent) yet. Portly detected \(dependencies.manager.displayName).")
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Info bar

    private var infoBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                StatusBadge(state: runtime.state)

                if let pid = runtime.pid {
                    fact("PID \(pid)", icon: .hashtag)
                }
                if let port = runtime.effectivePort {
                    fact(runtime.portFallback == nil ? "Port \(port)" : "Port \(port) (wanted \(runtime.config.port ?? port))", icon: .network)
                }
                ForEach(runtime.extraPorts, id: \.self) { port in
                    fact("+ :\(port)", icon: .network)
                }
                if let startedAt = runtime.startedAt, runtime.isRunning {
                    fact("Up \(startedAt.compactUptime)", icon: .clock)
                }
                if let action = runtime.runningAction {
                    fact("Action \(action.name)", icon: .bolt)
                }
                if runtime.restartCount > 0 {
                    fact(
                        "\(runtime.restartCount)/\(supervisor.settings.maxRestartAttempts) restarts",
                        icon: .restart
                    )
                }
                if let dependencies = runtime.dependencies, !dependencies.installed, !runtime.isRunning {
                    NucleoLabel("Dependencies missing", icon: .warning, size: 11)
                        .font(PortlyTypography.metadata)
                        .foregroundStyle(.orange)
                        .transition(.opacity)
                }

                Spacer()

                if let error = runtime.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(error)
                }

                if runtime.processMetrics != nil {
                    Button {
                        showsResources.toggle()
                    } label: {
                        NucleoIconView(.chartBar, size: 14)
                            .foregroundStyle(showsResources ? Color.accentColor : Color.secondary)
                            .frame(width: 24, height: 24)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(showsResources ? Color.accentColor.opacity(0.12) : .clear)
                            }
                    }
                    .buttonStyle(.borderless)
                    .help(showsResources ? "Hide resource use" : "Show resource use")
                    .accessibilityLabel(showsResources ? "Hide resource use" : "Show resource use")
                }
            }

            if let metrics = runtime.processMetrics, showsResources {
                HStack(spacing: 18) {
                    compactResource(
                        value: metrics.cpuPercent.formatted(.number.precision(.fractionLength(1))) + "%",
                        icon: .cpu,
                        color: metrics.cpuPressure.color,
                        label: "CPU",
                        help: "Total CPU used by this server and its child processes"
                    )
                    compactResource(
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(metrics.memoryBytes),
                            countStyle: .memory
                        ),
                        icon: .memory,
                        color: metrics.memoryPressure.color,
                        label: "Memory",
                        help: "Total memory owned by this server and its child processes"
                    )
                    compactResource(
                        value: String(metrics.processCount),
                        icon: .layers,
                        color: .blue,
                        label: "Processes",
                        help: "Processes Portly groups together for this server"
                    )

                    Spacer()

                    Button {
                        AppSelection.shared.pending = .resources
                    } label: {
                        NucleoLabel("Details", icon: .arrowUpRight)
                    }
                    .buttonStyle(.borderless)
                    .help("Open the resource dashboard")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func fact(_ text: String, icon: AppIcon) -> some View {
        NucleoLabel(text, icon: icon, size: 11)
            .font(PortlyTypography.metadata)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func compactResource(
        value: String,
        icon: AppIcon,
        color: Color,
        label: String,
        help: String
    ) -> some View {
        HStack(spacing: 6) {
            NucleoIconView(icon, size: 12)
                .foregroundStyle(color)
            Text(value)
                .font(PortlyTypography.metric)
                .monospacedDigit()
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityHint(help)
    }

    // MARK: - Port conflict

    private func conflictBanner(_ occupant: PortOccupant) -> some View {
        HStack(spacing: 10) {
            NucleoIconView(.warning, size: 14)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(occupant.dockerContainerID == nil ? "Running outside Portly" : "Docker container outside Portly")
                    .font(.system(size: 12, weight: .medium))
                Text(conflictDescription(occupant))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if supervisor.settings.autoSelectFreePort {
                Text("Start uses the next free port")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button(occupant.dockerContainerID == nil ? "Stop process" : "Stop container") {
                stopConflictOwner(occupant)
            }
            .controlSize(.small)
            Button("Move to Portly") {
                if runtime.takeOverPort() { conflict = nil }
            }
            .controlSize(.small)
            .help("Stop the current owner safely, then start \(runtime.projectName) / \(runtime.config.name) under Portly")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    private func conflictDescription(_ occupant: PortOccupant) -> String {
        if let name = occupant.dockerContainerName {
            let service = [occupant.dockerComposeProject, occupant.dockerComposeService]
                .compactMap { $0 }
                .joined(separator: " / ")
            let identity = service.isEmpty ? name : service
            return "\(identity) publishes port \(occupant.port) through Docker Desktop (backend pid \(occupant.pid))."
        }
        return "\(occupant.command) (pid \(occupant.pid)) is using port \(occupant.port)."
    }

    private func stopConflictOwner(_ occupant: PortOccupant) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                PortInspector.stopOccupant(of: occupant.port, expectedPID: occupant.pid)
            }.value
            switch result {
            case .success:
                try? await Task.sleep(for: .milliseconds(500))
                refreshConflict()
            case .failure(let error):
                conflictActionError = error.localizedDescription
            }
        }
    }

    /// Only interesting when our own server is not the listener.
    private func refreshConflict() {
        guard let port = runtime.config.port, !runtime.isRunning else {
            conflict = nil
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = supervisor.occupant(of: port)
            DispatchQueue.main.async { conflict = found }
        }
    }
}
